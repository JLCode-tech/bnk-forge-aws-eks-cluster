# =============================================================================
# eks-cluster-tmm-heal — best-effort cold-start heals (awsbnkctl phase24/24b/24c)
# =============================================================================
# Runs AFTER cneinstall (CNEInstance applied, FLO rolling out the runtime) and
# BEFORE the readiness gate. Clears the three known BNK 2.3 cold-start races
# (cwc DNS-warmup, dssm TLS-hostname, f5-tmm-pod-manager kube-proxy) that left
# the live D-031 retrofit's control plane wedged. Every path is best-effort —
# the script always exits 0; the ready-gate is the real check. See D-033.

resource "null_resource" "tmm_heal" {
  triggers = {
    cluster        = var.eks_cluster_name
    operator_ns    = var.operator_namespace
    instance_ns    = var.instance_namespace
    cneinstall_dep = tostring(var.cneinstall_ready)
    script_hash    = filesha256("${path.module}/scripts/tmm-heal.sh")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      EKS_CLUSTER_NAME      = var.eks_cluster_name
      AWS_REGION            = var.aws_region
      AWS_ACCESS_KEY_ID     = var.aws_access_key_id
      AWS_SECRET_ACCESS_KEY = var.aws_secret_access_key
      AWS_SESSION_TOKEN     = var.aws_session_token
      OPERATOR_NAMESPACE    = var.operator_namespace
      INSTANCE_NAMESPACE    = var.instance_namespace
      KUBECONFIG_OUT        = "${path.module}/work/kubeconfig"
    }
    command = "bash '${path.module}/scripts/tmm-heal.sh'"
  }
}
