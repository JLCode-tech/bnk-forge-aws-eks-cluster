# =============================================================================
# eks-cluster-install-tmm-nads
# =============================================================================
# Installs Multus CNI and creates the two NetworkAttachmentDefinitions the HP
# variant blueprints reference in their CNEInstance CRs:
#   - ens7-ipvlan-l2 → external data-plane interface on the hp-nodes ens7 ENI
#   - ens8-ipvlan-l2 → internal data-plane interface on the hp-nodes ens8 ENI
#
# Replaces the manual "apply the YAMLs from the F5 install guide" prerequisite
# the -with-hp-nodes blueprints previously documented. AWS EKS does not ship
# Multus by default; without it the TMM secondary network attachments are
# rejected by the kubelet.
#
# The CNI 'static' IPAM type requires at least one address. We derive the
# placeholder from the first f5-bnk-role-tagged subnet discovered in the
# cluster VPC at apply time, so the NAD is internally consistent with the
# subnet TMM's secondary ENI actually lives on.
#
# Sequence:
#   1. Apply the Multus daemonset manifest from upstream (or vendored mirror).
#   2. Wait for the multus-cni-config ConfigMap + multus-daemonset pods to be
#      ready (so the NetworkAttachmentDefinition CRD exists before we apply
#      the CRs).
#   3. Apply the external NAD (ens7-ipvlan-l2 by default).
#   4. Apply the internal NAD (ens8-ipvlan-l2 by default).

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
  token      = var.aws_session_token != "" ? var.aws_session_token : null
}

# =============================================================================
# TMM subnet discovery (tag-based, scoped to the cluster VPC)
# =============================================================================
# Same query cneinstall runs, here so the NAD's static-address placeholder
# can be derived from the discovered subnet's CIDR. Means the placeholder is
# inside the actual subnet TMM's ENI lives on — not the hardcoded 10.10.1.1.

data "aws_subnets" "tmm_external_discovered" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  tags = {
    "f5-bnk-role" = "tmm-external"
  }
}

data "aws_subnet" "tmm_external_discovered" {
  for_each = toset(data.aws_subnets.tmm_external_discovered.ids)
  id       = each.value
}

data "aws_subnets" "tmm_internal_discovered" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  tags = {
    "f5-bnk-role" = "tmm-internal"
  }
}

data "aws_subnet" "tmm_internal_discovered" {
  for_each = toset(data.aws_subnets.tmm_internal_discovered.ids)
  id       = each.value
}

# =============================================================================
# Forge-injected kubeconfig
# =============================================================================

resource "local_sensitive_file" "kubeconfig" {
  filename        = "${path.module}/work/kubeconfig"
  file_permission = "0600"
  content         = try(local.forge_kubeconfig, var.forge_kubeconfig_content)
}

locals {
  kubectl = "kubectl --kubeconfig ${local_sensitive_file.kubeconfig.filename}"

  multus_url = var.multus_manifest_url != "" ? var.multus_manifest_url : "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${var.multus_version}/deployments/multus-daemonset.yml"

  # Sorted lists of discovered subnet CIDRs. Sort = deterministic pick when
  # multiple AZs are tagged; we always take index [0] for the NAD placeholder.
  tmm_external_cidrs = sort([
    for s in data.aws_subnet.tmm_external_discovered : s.cidr_block
  ])
  tmm_internal_cidrs = sort([
    for s in data.aws_subnet.tmm_internal_discovered : s.cidr_block
  ])

  # 3-tier static-address resolution per NAD:
  #   1. Explicit user override → use it verbatim.
  #   2. Discovery returned subnets → cidrhost(cidr, 1) + matching prefix.
  #   3. Both empty → fallback (default F5 reference 10.10.1.1/24).
  #
  # cidrhost(cidr, 1) picks the first usable host in the subnet (.1). The
  # placeholder isn't routed — F5 IPAM operator overrides at runtime — but
  # keeping it inside the subnet matches what the kernel will see when the
  # ENI is configured.
  nad_external_static_address = (
    var.nad_external_static_address != ""
    ? var.nad_external_static_address
    : (
      length(local.tmm_external_cidrs) > 0
      ? "${cidrhost(local.tmm_external_cidrs[0], 1)}/${split("/", local.tmm_external_cidrs[0])[1]}"
      : var.nad_static_address_fallback
    )
  )

  nad_internal_static_address = (
    var.nad_internal_static_address != ""
    ? var.nad_internal_static_address
    : (
      length(local.tmm_internal_cidrs) > 0
      ? "${cidrhost(local.tmm_internal_cidrs[0], 1)}/${split("/", local.tmm_internal_cidrs[0])[1]}"
      : var.nad_static_address_fallback
    )
  )

  nad_external_manifest = templatefile("${path.module}/manifests/nad.yaml.tftpl", {
    nad_name       = var.nad_external_name
    nad_namespace  = var.nad_namespace
    tmm_role       = "tmm-external"
    cni_type       = var.nad_cni_type
    master         = var.nad_external_master
    ipvlan_mode    = var.nad_ipvlan_mode
    static_address = local.nad_external_static_address
  })

  nad_internal_manifest = templatefile("${path.module}/manifests/nad.yaml.tftpl", {
    nad_name       = var.nad_internal_name
    nad_namespace  = var.nad_namespace
    tmm_role       = "tmm-internal"
    cni_type       = var.nad_cni_type
    master         = var.nad_internal_master
    ipvlan_mode    = var.nad_ipvlan_mode
    static_address = local.nad_internal_static_address
  })
}

# =============================================================================
# Multus install — fetches and applies the upstream daemonset manifest
# =============================================================================

resource "null_resource" "multus_install" {
  count = var.install_multus ? 1 : 0

  triggers = {
    multus_url      = local.multus_url
    kubeconfig_file = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      echo "[tmm-nads] applying multus from ${local.multus_url}"
      ${local.kubectl} apply -f "${local.multus_url}"

      # Wait for the CRD to be Established so the NAD applies below see it.
      ${local.kubectl} wait --for=condition=Established \
        --timeout=120s \
        crd/network-attachment-definitions.k8s.cni.cncf.io

      # Wait for the multus daemonset to roll out so the CNI binary is on every
      # node. Without this the first pods that need a secondary network can
      # fail to schedule with "no CNI configuration".
      ${local.kubectl} -n kube-system rollout status \
        ds/kube-multus-ds \
        --timeout=180s
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    on_failure  = continue
    command     = <<-EOT
      echo "[tmm-nads] removing multus (delete -f ${self.triggers.multus_url})"
      kubectl --kubeconfig ${self.triggers.kubeconfig_file} delete -f "${self.triggers.multus_url}" --ignore-not-found || true
    EOT
  }
}

# =============================================================================
# External NAD — TMM client-facing (ens7-ipvlan-l2)
# =============================================================================

resource "null_resource" "nad_external" {
  triggers = {
    manifest_sha    = sha256(local.nad_external_manifest)
    nad_name        = var.nad_external_name
    nad_namespace   = var.nad_namespace
    kubeconfig_file = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      echo "[tmm-nads] applying external NAD ${var.nad_external_name} (ns=${var.nad_namespace}) static=${local.nad_external_static_address}"
      cat <<'MANIFEST' | ${local.kubectl} apply -f -
${local.nad_external_manifest}
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    on_failure  = continue
    command     = "kubectl --kubeconfig ${self.triggers.kubeconfig_file} -n ${self.triggers.nad_namespace} delete net-attach-def ${self.triggers.nad_name} --ignore-not-found || true"
  }

  depends_on = [null_resource.multus_install]
}

# =============================================================================
# Internal NAD — TMM backend-facing (ens8-ipvlan-l2)
# =============================================================================

resource "null_resource" "nad_internal" {
  triggers = {
    manifest_sha    = sha256(local.nad_internal_manifest)
    nad_name        = var.nad_internal_name
    nad_namespace   = var.nad_namespace
    kubeconfig_file = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      echo "[tmm-nads] applying internal NAD ${var.nad_internal_name} (ns=${var.nad_namespace}) static=${local.nad_internal_static_address}"
      cat <<'MANIFEST' | ${local.kubectl} apply -f -
${local.nad_internal_manifest}
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    on_failure  = continue
    command     = "kubectl --kubeconfig ${self.triggers.kubeconfig_file} -n ${self.triggers.nad_namespace} delete net-attach-def ${self.triggers.nad_name} --ignore-not-found || true"
  }

  depends_on = [null_resource.multus_install]
}
