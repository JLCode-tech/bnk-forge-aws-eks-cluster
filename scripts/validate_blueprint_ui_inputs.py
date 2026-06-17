#!/usr/bin/env python3
"""
validate_blueprint_ui_inputs.py

Emulates ImportedBlueprintService.get_required_inputs() using:
  - forge-blueprint.json (the manifest)
  - module bnkforge.pack.json schemas (primary — matches Forge stored schema)
  - module variables.tf files (secondary — catches vars not yet in pack.json)

Forge parses TF directly via terraform-config-inspect; pack.json can lag behind
new variables added to .tf files. This script mirrors Forge by reading both:
  1. pack.json for the authoritative stored schema
  2. variables.tf HCL (regex parse) for any vars missing from pack.json

A module variable is VISIBLE-REQUIRED when:
  - It has no default (TF required), AND
  - It is not covered by a top-level blueprint source=module/credential_template/
    project/project_secret declaration (which means Forge auto-resolves it).

Prints visible required inputs. Exit 0 if zero visible required inputs, else 1.

Usage: python3 scripts/validate_blueprint_ui_inputs.py <blueprint-dir>
  e.g. python3 scripts/validate_blueprint_ui_inputs.py blueprints/aws-eks-bnk23-traffic
"""

import json
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)

CONTEXT_RESOLVED_SOURCES = {"credential_template", "project", "project_secret", "module"}

# Sentinel: a variable has no default in TF (i.e. it is TF-required).
_NO_DEFAULT = object()


def _parse_tf_variables(tf_path: str) -> list[dict]:
    """
    Parse a variables.tf file with a simple regex approach.

    Returns list of dicts with: name, has_default (bool).
    We don't need to evaluate the actual default value — only whether one exists,
    because Forge considers a TF variable without a default as user-required.

    Handles:
      variable "name" {
        ...
        default = <anything>
        ...
      }
    Multi-line blocks are supported via block-level scanning.
    """
    if not os.path.exists(tf_path):
        return []
    with open(tf_path) as f:
        content = f.read()

    results = []
    # Split on variable block boundaries
    # Match: variable "name" { ... }  (greedy block match)
    # We walk line-by-line tracking brace depth.
    var_name = None
    brace_depth = 0
    in_var_block = False
    block_lines: list[str] = []

    for line in content.splitlines():
        m = re.match(r'\s*variable\s+"([^"]+)"\s*\{', line)
        if m and not in_var_block:
            var_name = m.group(1)
            in_var_block = True
            brace_depth = line.count("{") - line.count("}")
            block_lines = [line]
            continue

        if in_var_block:
            block_lines.append(line)
            brace_depth += line.count("{") - line.count("}")
            if brace_depth <= 0:
                # End of block — check for 'default'
                block_text = "\n".join(block_lines)
                has_default = bool(re.search(r'^\s*default\s*=', block_text, re.MULTILINE))
                results.append({"name": var_name, "has_default": has_default})
                in_var_block = False
                var_name = None
                block_lines = []
                brace_depth = 0

    return results


def load_module_vars(module_ref: str) -> list[dict]:
    """
    Load module variable declarations from BOTH pack.json and variables.tf.

    pack.json is authoritative for vars it knows about (matches Forge stored schema).
    variables.tf catches vars that were added to TF but not yet surfaced in pack.json —
    exactly the gap that caused the false-pass on v0.5.2.

    Returns list of dicts: {name, required (bool), source (None — tf-parse strips it)}
    """
    module_path = os.path.join(REPO_ROOT, module_ref)
    schema_path = os.path.join(module_path, "bnkforge.pack.json")
    tf_path = os.path.join(module_path, "variables.tf")

    pack_vars: dict[str, dict] = {}
    if os.path.exists(schema_path):
        with open(schema_path) as f:
            schema = json.load(f)
        inputs = schema.get("inputs", {})
        for var in inputs.get("required", []):
            pack_vars[var["name"]] = {"name": var["name"], "required": True, "source": None}
        for var in inputs.get("optional", []):
            pack_vars[var["name"]] = {"name": var["name"], "required": False, "source": None}

    # Augment with TF parse — add vars missing from pack.json
    tf_vars = _parse_tf_variables(tf_path)
    result = dict(pack_vars)
    for tv in tf_vars:
        n = tv["name"]
        if n not in result:
            # Forge treats no-default as required, has-default as optional
            result[n] = {
                "name": n,
                "required": not tv["has_default"],
                "source": None,
                "_from_tf_only": True,
            }

    return list(result.values())


def get_required_inputs(manifest: dict) -> dict:
    """Emulate ImportedBlueprintService.get_required_inputs()."""
    inputs = manifest.get("inputs") or {}
    required_inputs = inputs.get("required") or []
    optional_inputs = inputs.get("optional") or []

    # Build context_resolved_names from blueprint top-level inputs
    context_resolved_names: set[str] = set()
    for item in required_inputs + optional_inputs:
        if isinstance(item, dict) and item.get("source") in CONTEXT_RESOLVED_SOURCES:
            name = item.get("name")
            if name:
                context_resolved_names.add(name)

    def normalize_input(item: dict, is_req: bool) -> dict:
        source = item.get("source")
        is_hidden = source in CONTEXT_RESOLVED_SOURCES
        return {
            "name": item.get("name"),
            "type": item.get("type", "string"),
            "description": item.get("description", ""),
            "default": item.get("default"),
            "required": is_req and not is_hidden,
            "hidden": is_hidden,
            "source": source,
        }

    all_inputs = (
        [normalize_input(i, True) for i in required_inputs] +
        [normalize_input(i, False) for i in optional_inputs]
    )

    # Seed seen_required_names from blueprint level
    seen_required_names: set[str] = set()
    for item in all_inputs:
        if item["required"] and not item["hidden"]:
            if item["name"]:
                seen_required_names.add(item["name"])

    total_optional = len(optional_inputs)

    # Process module-level vars (pack.json + variables.tf)
    for module_def in manifest.get("modules") or []:
        module_ref = str(module_def.get("module") or "").strip()
        if not module_ref:
            continue
        variables_schema = load_module_vars(module_ref)
        if not variables_schema:
            print(f"  WARNING: no schema found for {module_ref}")
            continue
        module_inputs_literal = (
            module_def.get("inputs") if isinstance(module_def.get("inputs"), dict) else {}
        )
        for var_def in variables_schema:
            vname = var_def.get("name")
            if not vname:
                continue
            literal_default = module_inputs_literal.get(vname)
            is_required = bool(var_def.get("required"))
            var_source = var_def.get("source")  # None after tf-parse
            is_hidden = (var_source in CONTEXT_RESOLVED_SOURCES) or (
                vname in context_resolved_names
            )
            # If the module declaration hard-wires a literal value, it's not user-visible
            if literal_default is not None:
                is_hidden = True
            entry = {
                "name": vname,
                "required": is_required and not is_hidden,
                "hidden": is_hidden,
                "source": var_source,
                "module_ref": module_ref,
                "default": literal_default if literal_default is not None else var_def.get("default"),
                "_from_tf_only": var_def.get("_from_tf_only", False),
            }
            all_inputs.append(entry)
            if not is_hidden and not is_required:
                total_optional += 1

    # Final count — deduplicated by name
    for item in all_inputs:
        if item.get("required") and not item.get("hidden"):
            name = item.get("name")
            if name:
                seen_required_names.add(name)

    total_required = len(seen_required_names)

    # Collect TF-only visible vars (both required and optional) — these are module vars
    # that Forge will surface to the user but are not declared in the blueprint at all.
    # These indicate missing source=module declarations in the blueprint optional list.
    tf_only_visible_names: list[str] = []
    seen_tf_visible: set[str] = set()
    for item in all_inputs:
        if item.get("_from_tf_only") and not item.get("hidden"):
            n = item.get("name")
            if n and n not in seen_tf_visible:
                tf_only_visible_names.append(n)
                seen_tf_visible.add(n)

    return {
        "total_required": total_required,
        "total_optional": total_optional,
        "visible_required_names": sorted(seen_required_names),
        "context_resolved_names": sorted(context_resolved_names),
        "all_inputs": all_inputs,
        "tf_only_visible_names": sorted(tf_only_visible_names),
    }


def main():
    if len(sys.argv) < 2:
        blueprint_dir = "blueprints/aws-eks-bnk23-traffic"
    else:
        blueprint_dir = sys.argv[1]

    bp_path = os.path.join(REPO_ROOT, blueprint_dir, "forge-blueprint.json")
    if not os.path.exists(bp_path):
        print(f"ERROR: {bp_path} not found")
        sys.exit(1)

    with open(bp_path) as f:
        manifest = json.load(f)

    print(f"Blueprint: {manifest['blueprint']['id']} v{manifest['blueprint']['version']}")
    print()

    result = get_required_inputs(manifest)

    print(f"context_resolved_names ({len(result['context_resolved_names'])}):")
    for n in result["context_resolved_names"]:
        print(f"  {n}")
    print()

    print(f"Visible required inputs ({result['total_required']}):")
    for n in result["visible_required_names"]:
        print(f"  ✓ {n}")
    print()

    # Report TF-only visible vars (present in .tf but not in pack.json AND not in blueprint)
    # These are what Forge shows to the user that the blueprint fails to hide.
    if result["tf_only_visible_names"]:
        print(
            f"TF-only visible inputs NOT declared in blueprint ({len(result['tf_only_visible_names'])}):"
        )
        for n in result["tf_only_visible_names"]:
            # find module_ref
            refs = sorted({
                i["module_ref"]
                for i in result["all_inputs"]
                if i.get("name") == n and i.get("_from_tf_only") and i.get("module_ref")
            })
            print(f"  ✗ {n} [{', '.join(refs)}]")
        print()

    # Highlight module-level visible required for diagnosis
    module_visible = []
    for item in result["all_inputs"]:
        if item.get("required") and not item.get("hidden") and item.get("module_ref"):
            module_visible.append(f"  {item['name']} [{item['module_ref']}]")
    if module_visible:
        print(f"Module-level visible required (counted once via dedup):")
        for line in sorted(set(module_visible)):
            print(line)
        print()

    print(f"Total required: {result['total_required']}")
    print(f"Total optional: {result['total_optional']}")
    print()

    # PASS requires:
    #   1. Zero visible required inputs (eks_cluster_name is now context-resolved from project name)
    #   2. No TF-only visible vars (pack.json or blueprint is missing declarations for them)
    tf_only_count = len(result["tf_only_visible_names"])
    required_ok = result["total_required"] == 0
    tf_only_ok = tf_only_count == 0

    if required_ok and tf_only_ok:
        print("✅ PASS: zero visible required fields (eks_cluster_name resolved from project name)")
        print("✅ PASS: no TF-only visible inputs missing from blueprint declarations")
        sys.exit(0)
    else:
        if not required_ok:
            print(
                f"❌ FAIL: expected 0 visible required inputs, "
                f"got {result['total_required']}: {result['visible_required_names']}"
            )
        if not tf_only_ok:
            print(
                f"❌ FAIL: {tf_only_count} module vars visible in Forge UI but not declared in "
                f"blueprint optional (add source=module entries to hide them): "
                f"{result['tf_only_visible_names']}"
            )
        sys.exit(1)


if __name__ == "__main__":
    main()
