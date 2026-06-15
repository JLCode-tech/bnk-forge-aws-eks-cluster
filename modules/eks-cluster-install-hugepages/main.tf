# =============================================================================
# install-hugepages
# =============================================================================
# Cloud-agnostic primitive: apply a hugepages DaemonSet on BNK worker nodes.
#
# F5 TMM requires hugepages-2Mi capacity on every node it runs on. This
# DaemonSet sets vm.nr_hugepages=2048 (4 GB of 2 Mi hugepages) on all nodes
# labelled role=bnk, then restarts kubelet so the capacity surfaces in
# .status.capacity.hugepages-2Mi before downstream phases schedule TMM.
#
# Manifest source:
#   awsbnkctl:internal/k8s/manifests/shared/hugepages-ds.yaml
#   awsbnkctl:internal/aws/phases/phase11b_ebs_csi_hugepages.go (apply + wait logic)
#
# Sequence (mirrors awsbnkctl Phase 11b.2 and 11b.3):
#   1. kubectl apply the hugepages-setup DaemonSet in kube-system.
#   2. kubectl rollout status waits for the DS to become Ready on all
#      role=bnk nodes.
#
# Note: the awsbnkctl gold standard also waits for the kubelet on the TMM node
# to re-advertise hugepages-2Mi capacity (Phase 11b.3, up to 5 min). That
# per-node gate is omitted here because Forge has no per-node polling primitive
# — the per-cloud eks-cluster-install-hugepages wrapper may add it as a
# data.external check if needed.
#
# Destroy: deletes the DaemonSet with --ignore-not-found.

resource "local_sensitive_file" "kubeconfig" {
  filename        = "${path.module}/work/kubeconfig"
  file_permission = "0600"
  content         = try(local.forge_kubeconfig, var.forge_kubeconfig_content)
}

locals {
  kubectl            = "kubectl --kubeconfig ${local_sensitive_file.kubeconfig.filename}"
  hugepages_manifest = "${path.module}/manifests/hugepages-ds.yaml"
  gp3_sc_manifest    = "${path.module}/manifests/gp3-storageclass.yaml"
}

# F17: gp3 (EBS CSI) default StorageClass. BNK dSSM PVCs request "gp3" but EKS
# only ships in-tree "gp2" -> PVCs Pending, dSSM never reaches quorum. Applied
# here (post-cluster k8s bootstrap, alongside hugepages) so the SC exists before
# the CNEInstance creates dSSM PVCs. Independent of install_hugepages.
resource "null_resource" "gp3_storageclass" {
  triggers = {
    manifest        = filemd5(local.gp3_sc_manifest)
    kubeconfig_file = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      echo "[install-hugepages] applying gp3 EBS-CSI default StorageClass"
      ${local.kubectl} apply -f "${local.gp3_sc_manifest}"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    on_failure  = continue
    command     = <<-EOT
      echo "[install-hugepages] removing gp3 StorageClass"
      kubectl --kubeconfig "${self.triggers.kubeconfig_file}" delete \
        -f "${path.module}/manifests/gp3-storageclass.yaml" --ignore-not-found || true
    EOT
  }
}

resource "null_resource" "hugepages_install" {
  count = var.install_hugepages ? 1 : 0

  triggers = {
    manifest        = filemd5(local.hugepages_manifest)
    kubeconfig_file = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      echo "[install-hugepages] applying hugepages-setup DaemonSet"
      ${local.kubectl} apply -f "${local.hugepages_manifest}"

      echo "[install-hugepages] waiting for hugepages-setup DaemonSet rollout (up to ${var.daemonset_rollout_timeout})"
      ${local.kubectl} -n kube-system rollout status \
        ds/hugepages-setup \
        --timeout=${var.daemonset_rollout_timeout}

      echo "[install-hugepages] complete"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    on_failure  = continue
    command     = <<-EOT
      echo "[install-hugepages] removing hugepages-setup DaemonSet"
      kubectl --kubeconfig "${self.triggers.kubeconfig_file}" delete \
        -f "${path.module}/manifests/hugepages-ds.yaml" --ignore-not-found || true
    EOT
  }
}
