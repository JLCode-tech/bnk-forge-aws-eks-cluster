# =============================================================================
# install-multus
# =============================================================================
# Cloud-agnostic primitive: install Multus CNI on a Kubernetes cluster.
#
# Multus is a meta-CNI that lets pods attach to multiple networks (one CNI
# manages the primary pod interface, Multus chains additional interfaces via
# NetworkAttachmentDefinition CRs). BNK's TMM data-plane model requires
# Multus when TMM pods need secondary host interfaces (external + internal
# data planes). AWS EKS, Azure AKS, and GCP GKE do NOT ship Multus by
# default; on-prem clusters may or may not.
#
# This module ONLY installs Multus. The NetworkAttachmentDefinitions that
# BNK TMM consumes are created by a downstream per-cloud module
# (e.g. eks-cluster-install-tmm-nads on AWS) — those are cloud-specific
# because the host interface names + IPAM source differ per cloud.
#
# Sequence:
#   1. kubectl apply the multus-daemonset manifest from the upstream URL.
#   2. kubectl wait for the NetworkAttachmentDefinition CRD to be Established.
#   3. kubectl rollout status on the kube-multus-ds DaemonSet so the CNI
#      binary is on every node before any pods needing secondary networks
#      schedule.

resource "local_sensitive_file" "kubeconfig" {
  filename        = "${path.module}/work/kubeconfig"
  file_permission = "0600"
  content         = try(local.forge_kubeconfig, var.forge_kubeconfig_content)
}

locals {
  kubectl = "kubectl --kubeconfig ${local_sensitive_file.kubeconfig.filename}"

  multus_url = var.multus_manifest_url != "" ? var.multus_manifest_url : "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${var.multus_version}/deployments/multus-daemonset.yml"
}

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
      echo "[install-multus] applying multus from ${local.multus_url}"
      ${local.kubectl} apply -f "${local.multus_url}"

      echo "[install-multus] waiting for NetworkAttachmentDefinition CRD"
      ${local.kubectl} wait --for=condition=Established \
        --timeout=${var.multus_crd_wait_timeout} \
        crd/network-attachment-definitions.k8s.cni.cncf.io

      echo "[install-multus] waiting for kube-multus-ds rollout"
      ${local.kubectl} -n kube-system rollout status \
        ds/kube-multus-ds \
        --timeout=${var.multus_rollout_wait_timeout}

      echo "[install-multus] complete"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    on_failure  = continue
    command     = <<-EOT
      echo "[install-multus] removing multus (delete -f ${self.triggers.multus_url})"
      kubectl --kubeconfig ${self.triggers.kubeconfig_file} delete -f "${self.triggers.multus_url}" --ignore-not-found || true
    EOT
  }
}
