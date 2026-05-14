# =============================================================================
# eks-cluster-cneinstall
# =============================================================================
# All-in-one CNEInstance install + AWS IRSA wiring for an existing EKS cluster.
#
# What this module does, in order:
#   1. Renders + applies the cloud-network-mapping ConfigMap (AWS AZ→subnet
#      lookup table read by the CNE controller).
#   2. Renders + applies the CNEInstance CR. FLO observes the CR and rolls out
#      CWC, DSSM, Observer, OTEL, RabbitMQ, TMM, the F5 IPAM operator + their
#      ServiceAccounts.
#   3. Renders + applies the F5BnkGateway chassis CR — required on AWS/EKS for
#      Gateway-API translation (without it the CNE controller silently ignores
#      Gateway+HTTPRoute CRs even when CNEInstance is Programmed=True).
#   4. Creates the IRSA IAM policy + role for the CNE controller, with an OIDC
#      trust policy targeting the controller's ServiceAccount.
#   5. Waits for FLO to create the controller's SA, annotates it with
#      eks.amazonaws.com/role-arn, rollout-restarts the controller so the
#      EKS pod-identity-webhook injects credentials into a fresh pod.

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
  token      = var.aws_session_token != "" ? var.aws_session_token : null
}

# =============================================================================
# Forge-injected kubeconfig (used by kubectl in local-exec provisioners)
# =============================================================================

resource "local_sensitive_file" "kubeconfig" {
  filename        = "${path.module}/work/kubeconfig"
  file_permission = "0600"
  content         = try(local.forge_kubeconfig, var.forge_kubeconfig_content)
}

locals {
  kubectl = "kubectl --kubeconfig ${local_sensitive_file.kubeconfig.filename}"

  # Smart tmm_replicas default: when caller passes 0 (the sentinel), derive
  # from cluster topology. The 1-TMM-per-AZ pattern is the F5 install guide's
  # default; cap at worker_node_count so we never request more TMM pods than
  # there are nodes to schedule them on.
  effective_tmm_replicas = (
    var.tmm_replicas > 0
    ? var.tmm_replicas
    : min(var.availability_zone_count, var.worker_node_count)
  )

  # Derive F5BnkGateway chassis listener networks from a single vip_cidr.
  # Empty vip_cidr → skip the chassis CR entirely (preserved-on-prem default).
  vip_chassis_enabled = var.vip_cidr != ""

  chassis_listener_networks = local.vip_chassis_enabled ? [{
    name          = var.vip_network_name
    start_address = cidrhost(var.vip_cidr, 1)
    end_address   = cidrhost(var.vip_cidr, -2)
  }] : []

  cneinstance_manifest = templatefile("${path.module}/manifests/cneinstance.yaml.tftpl", {
    instance_name       = var.instance_name
    instance_namespace  = var.operator_namespace
    manifest_version    = var.manifest_version
    cluster_issuer_name = var.cluster_issuer_name
    deployment_size     = var.deployment_size
    storage_class_name  = var.storage_class_name
    far_secret_name     = var.far_secret_name
    network_attachments = var.network_attachments
    watch_namespaces    = var.watch_namespaces
    tmm_replicas        = local.effective_tmm_replicas
  })

  cloud_network_mapping_manifest = templatefile("${path.module}/manifests/cloud-network-mapping.yaml.tftpl", {
    instance_namespace = var.operator_namespace
    az_subnet_mappings = var.cloud_az_subnet_mappings
  })

  f5_bnkgateway_manifest = templatefile("${path.module}/manifests/f5-bnkgateway-chassis.yaml.tftpl", {
    instance_namespace        = var.operator_namespace
    chassis_name              = var.chassis_name
    default_listener_networks = local.chassis_listener_networks
  })

  oidc_host_path        = replace(var.cluster_oidc_issuer_url, "https://", "")
  oidc_provider_arn     = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_host_path}"
  effective_role_name   = "${var.eks_cluster_name}-cne-controller-vip"
  effective_policy_name = "${var.eks_cluster_name}-allow-ec2-vip"

  common_tags = merge(var.tags, {
    module  = "eks-cluster-cneinstall"
    cluster = var.eks_cluster_name
  })
}

data "aws_caller_identity" "current" {}

# =============================================================================
# 1. cloud-network-mapping ConfigMap (REQUIRED before CNEInstance CR — the CNE
#    controller reads it on startup; missing ConfigMap = silent failure to
#    compute multi-AZ TMM placement)
# =============================================================================

resource "null_resource" "cloud_network_mapping" {
  count = length(var.cloud_az_subnet_mappings) > 0 ? 1 : 0

  triggers = {
    manifest_hash   = sha256(local.cloud_network_mapping_manifest)
    kubeconfig_file = local_sensitive_file.kubeconfig.filename
    namespace       = var.operator_namespace
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "=== Applying cloud-network-mapping ConfigMap ==="
      cat <<'MANIFEST' | ${local.kubectl} apply -f -
${local.cloud_network_mapping_manifest}
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig ${self.triggers.kubeconfig_file} -n ${self.triggers.namespace} delete configmap cloud-network-mapping --ignore-not-found"
  }
}

# =============================================================================
# 2. CNEInstance CR — FLO observes this and deploys the BNK runtime
# =============================================================================

resource "null_resource" "cneinstance" {
  triggers = {
    manifest_hash   = sha256(local.cneinstance_manifest)
    kubeconfig_file = local_sensitive_file.kubeconfig.filename
    namespace       = var.operator_namespace
    name            = var.instance_name
    flo_ready       = tostring(var.flo_ready)
    crds_installed  = tostring(var.crds_installed)
  }

  depends_on = [
    null_resource.cloud_network_mapping,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      echo "=== Applying CNEInstance CR ${var.instance_name} in ${var.operator_namespace} ==="
      cat <<'MANIFEST' | ${local.kubectl} apply -f -
${local.cneinstance_manifest}
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig ${self.triggers.kubeconfig_file} -n ${self.triggers.namespace} delete cneinstance ${self.triggers.name} --ignore-not-found"
  }
}

# =============================================================================
# 3. F5BnkGateway chassis CR (AWS — Gateway-API translation pipeline trigger)
# =============================================================================

resource "null_resource" "f5_bnkgateway_chassis" {
  count = local.vip_chassis_enabled ? 1 : 0

  triggers = {
    manifest_hash   = sha256(local.f5_bnkgateway_manifest)
    kubeconfig_file = local_sensitive_file.kubeconfig.filename
    namespace       = var.operator_namespace
    name            = var.chassis_name
  }

  depends_on = [
    null_resource.cneinstance,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      echo "=== Applying F5BnkGateway chassis ${var.chassis_name} (VIP CIDR ${var.vip_cidr}) ==="
      cat <<'MANIFEST' | ${local.kubectl} apply -f -
${local.f5_bnkgateway_manifest}
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig ${self.triggers.kubeconfig_file} -n ${self.triggers.namespace} delete f5-bnkgateway ${self.triggers.name} --ignore-not-found"
  }
}

# =============================================================================
# 4. IRSA — IAM policy + role + OIDC trust
# =============================================================================

resource "aws_iam_policy" "cne_controller_vip" {
  name        = local.effective_policy_name
  description = "Allow F5 CNE controller to attach VIPs/selfips as secondary IPs on the TMM data-plane ENI (BNK on EKS)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role" "cne_controller" {
  name        = local.effective_role_name
  description = "IRSA role for F5 CNE controller — assumed by SA ${var.operator_namespace}/${var.cne_controller_sa_name} on cluster ${var.eks_cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = local.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_host_path}:aud" = "sts.amazonaws.com"
            "${local.oidc_host_path}:sub" = "system:serviceaccount:${var.operator_namespace}:${var.cne_controller_sa_name}"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    "k8s-namespace"      = var.operator_namespace
    "k8s-serviceaccount" = var.cne_controller_sa_name
  })
}

resource "aws_iam_role_policy_attachment" "cne_controller_vip" {
  role       = aws_iam_role.cne_controller.name
  policy_arn = aws_iam_policy.cne_controller_vip.arn
}

resource "aws_iam_role_policy_attachment" "extra" {
  for_each   = toset(var.extra_irsa_managed_policy_arns)
  role       = aws_iam_role.cne_controller.name
  policy_arn = each.value
}

# =============================================================================
# 5. Annotate the CNE controller SA + rollout-restart the deployment
# =============================================================================
# FLO creates the SA only after reconciling the CNEInstance CR. We wait, then
# annotate, then restart so the EKS pod-identity-webhook injects credentials
# into a fresh controller pod.

resource "null_resource" "annotate_and_restart" {
  triggers = {
    role_arn        = aws_iam_role.cne_controller.arn
    sa              = "${var.operator_namespace}/${var.cne_controller_sa_name}"
    deployment      = "${var.operator_namespace}/${var.cne_controller_deployment_name}"
    kubeconfig_file = local_sensitive_file.kubeconfig.filename
  }

  depends_on = [
    aws_iam_role_policy_attachment.cne_controller_vip,
    null_resource.cneinstance,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      KUBECTL="${local.kubectl}"
      NS="${var.operator_namespace}"
      SA="${var.cne_controller_sa_name}"
      ROLE_ARN="${aws_iam_role.cne_controller.arn}"
      DEPLOY="${var.cne_controller_deployment_name}"
      TIMEOUT=${var.wait_for_sa_timeout_seconds}

      echo "=== Waiting for ServiceAccount $NS/$SA (max $${TIMEOUT}s) ==="
      ELAPSED=0
      INTERVAL=5
      while [ $ELAPSED -lt $TIMEOUT ]; do
        if $KUBECTL -n "$NS" get sa "$SA" >/dev/null 2>&1; then
          echo "ServiceAccount found after $${ELAPSED}s"
          break
        fi
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
      done

      if ! $KUBECTL -n "$NS" get sa "$SA" >/dev/null 2>&1; then
        echo "ERROR: ServiceAccount $NS/$SA never appeared after $${TIMEOUT}s"
        echo "Is the CNEInstance reconciling? Check:"
        echo "  $KUBECTL -n $NS get cneinstance"
        echo "  $KUBECTL -n $NS get pods"
        exit 1
      fi

      echo "=== Annotating $NS/$SA with eks.amazonaws.com/role-arn=$ROLE_ARN ==="
      $KUBECTL -n "$NS" annotate sa "$SA" \
        "eks.amazonaws.com/role-arn=$ROLE_ARN" \
        --overwrite

      if $KUBECTL -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1; then
        echo "=== Rollout-restarting deploy/$DEPLOY so IRSA env vars are injected ==="
        $KUBECTL -n "$NS" rollout restart "deploy/$DEPLOY"
        $KUBECTL -n "$NS" rollout status "deploy/$DEPLOY" --timeout=300s || \
          echo "WARNING: rollout did not finish within 300s — check pod status"
      else
        echo "INFO: deploy/$DEPLOY not found yet — IRSA will take effect on next pod creation"
      fi

      echo "=== IRSA wiring complete ==="
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      kubectl --kubeconfig ${self.triggers.kubeconfig_file} \
        -n ${split("/", self.triggers.sa)[0]} \
        annotate sa ${split("/", self.triggers.sa)[1]} \
        eks.amazonaws.com/role-arn- 2>/dev/null || true
    EOT
  }
}
