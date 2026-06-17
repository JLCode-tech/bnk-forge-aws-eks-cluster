#!/usr/bin/env python3
"""
validate_blueprint_ui_inputs.py

Emulates ImportedBlueprintService.get_required_inputs() using:
  - forge-blueprint.json (the manifest)
  - module bnkforge.pack.json schemas (as-stored in catalog)

Prints visible required inputs. Pass if exactly one.

Usage: python3 scripts/validate_blueprint_ui_inputs.py <blueprint-dir>
  e.g. python3 scripts/validate_blueprint_ui_inputs.py blueprints/aws-eks-bnk23-traffic
"""

import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)

CONTEXT_RESOLVED_SOURCES = {"credential_template", "project", "project_secret", "module"}


def load_module_schema(module_ref: str) -> list[dict]:
    """
    Load and normalize a module's variable declarations.

    Forge stores variables_schema from TF-file parsing (terraform-config-inspect),
    which produces: {name, type, description, default, required} — NO 'source' field.

    We simulate this by reading bnkforge.pack.json and:
      - marking all required[] vars as required=True, source=None
      - marking all optional[] vars as required=False, source=None
    This matches what Forge stores after tf-parse (source is stripped).
    """
    schema_path = os.path.join(REPO_ROOT, module_ref, "bnkforge.pack.json")
    if not os.path.exists(schema_path):
        return []
    with open(schema_path) as f:
        schema = json.load(f)
    inputs = schema.get("inputs", {})
    result = []
    for var in inputs.get("required", []):
        result.append({
            "name": var.get("name"),
            "type": var.get("type", "string"),
            "description": var.get("description", ""),
            "default": var.get("default"),
            "required": True,
            # No 'source' - tf-parse strips it
        })
    for var in inputs.get("optional", []):
        result.append({
            "name": var.get("name"),
            "type": var.get("type", "string"),
            "description": var.get("description", ""),
            "default": var.get("default"),
            "required": False,
            # No 'source' - tf-parse strips it
        })
    return result


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

    # Process module-level vars
    for module_def in manifest.get("modules") or []:
        module_ref = str(module_def.get("module") or "").strip()
        if not module_ref:
            continue
        variables_schema = load_module_schema(module_ref)
        if not variables_schema:
            print(f"  WARNING: no schema found for {module_ref}")
            continue
        module_inputs_literal = module_def.get("inputs") if isinstance(module_def.get("inputs"), dict) else {}
        for var_def in variables_schema:
            vname = var_def.get("name")
            if not vname:
                continue
            literal_default = module_inputs_literal.get(vname)
            is_required = bool(var_def.get("required"))
            var_source = var_def.get("source")  # None after tf-parse
            is_hidden = (var_source in CONTEXT_RESOLVED_SOURCES) or (vname in context_resolved_names)
            entry = {
                "name": vname,
                "required": is_required and not is_hidden,
                "hidden": is_hidden,
                "source": var_source,
                "module_ref": module_ref,
                "default": literal_default if literal_default is not None else var_def.get("default"),
            }
            all_inputs.append(entry)
            if not is_hidden:
                if not is_required:
                    total_optional += 1

    # Final count - deduplicated
    for item in all_inputs:
        if item.get("required") and not item.get("hidden"):
            name = item.get("name")
            if name:
                seen_required_names.add(name)

    total_required = len(seen_required_names)

    return {
        "total_required": total_required,
        "total_optional": total_optional,
        "visible_required_names": sorted(seen_required_names),
        "context_resolved_names": sorted(context_resolved_names),
        "all_inputs": all_inputs,
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
    for n in result['context_resolved_names']:
        print(f"  {n}")
    print()

    print(f"Visible required inputs ({result['total_required']}):")
    for n in result['visible_required_names']:
        print(f"  ✓ {n}")
    print()

    # Check for any non-hidden required that are module-level
    module_visible = []
    for item in result['all_inputs']:
        if item.get('required') and not item.get('hidden') and item.get('module_ref'):
            module_visible.append(f"  {item['name']} [{item['module_ref']}]")
    if module_visible:
        print(f"Module-level visible required (counted once via dedup):")
        for line in sorted(set(module_visible)):
            print(line)
        print()

    print(f"Total required: {result['total_required']}")
    print(f"Total optional: {result['total_optional']}")
    print()

    if result['total_required'] == 1 and result['visible_required_names'] == ['eks_cluster_name']:
        print("✅ PASS: exactly one visible required field: eks_cluster_name")
        sys.exit(0)
    else:
        print(f"❌ FAIL: expected 1 visible required (eks_cluster_name), got {result['total_required']}: {result['visible_required_names']}")
        sys.exit(1)


if __name__ == "__main__":
    main()
