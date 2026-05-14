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
# Sequence:
#   1. Apply the Multus daemonset manifest from upstream (or vendored mirror).
#   2. Wait for the multus-cni-config ConfigMap + multus-daemonset pods to be
#      ready (so the NetworkAttachmentDefinition CRD exists before we apply
#      the CRs).
#   3. Apply the external NAD (ens7-ipvlan-l2 by default).
#   4. Apply the internal NAD (ens8-ipvlan-l2 by default).

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

  nad_external_manifest = templatefile("${path.module}/manifests/nad.yaml.tftpl", {
    nad_name       = var.nad_external_name
    nad_namespace  = var.nad_namespace
    tmm_role       = "tmm-external"
    cni_type       = var.nad_cni_type
    master         = var.nad_external_master
    ipvlan_mode    = var.nad_ipvlan_mode
    static_address = var.nad_static_address
  })

  nad_internal_manifest = templatefile("${path.module}/manifests/nad.yaml.tftpl", {
    nad_name       = var.nad_internal_name
    nad_namespace  = var.nad_namespace
    tmm_role       = "tmm-internal"
    cni_type       = var.nad_cni_type
    master         = var.nad_internal_master
    ipvlan_mode    = var.nad_ipvlan_mode
    static_address = var.nad_static_address
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
      echo "[tmm-nads] applying external NAD ${var.nad_external_name} (ns=${var.nad_namespace})"
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
      echo "[tmm-nads] applying internal NAD ${var.nad_internal_name} (ns=${var.nad_namespace})"
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
