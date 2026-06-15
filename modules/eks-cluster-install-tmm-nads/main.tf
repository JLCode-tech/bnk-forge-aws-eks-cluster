# =============================================================================
# eks-cluster-install-tmm-nads — host-device TMM data-plane prep
# =============================================================================
# Prepares the TMM data plane on the host-device model (awsbnkctl phase16/17/17c/
# 20). Replaces the old ipvlan-l2 NADs with host-device NADs that bind the TMM
# pod directly to the real secondary ENIs (by PCI bus id) the hp-nodes bootstrap
# attached.
#
# Because the secondary ENIs are created by the node bootstrap (not Terraform),
# and because there is no native resource to assign a secondary private IP to an
# unmanaged ENI, the imperative work runs in scripts/discover-tmm-dataplane.sh:
#   1. label the single role=bnk node app=f5-tmm, resolve its instance-id;
#   2. find the two tagged ENIs (f5-bnk:tmm-role=external|internal), assign
#      SelfIP <subnet>.240 to each;
#   3. iface-discovery probe pod: MAC -> Linux ifname + PCI (BEFORE any TMM pod
#      claims the ENI into its netns);
#   4. apply host-device NADs (pciBusID) into nad_namespace + default.
#
# The discovered facts (ifname/PCI/SelfIP/subnet/AZ) are written to
# work/discovery.json and surfaced as module outputs for cneinstall to wire into
# the CNEInstance host-device env + F5SPKVlan SelfIPs + single-AZ
# cloud-network-mapping.
#
# Runs AFTER install-multus (NAD CRD present) and bnk-prereqs (nad_namespace
# exists), and BEFORE cneinstall (CNEInstance / TMM pods).

resource "null_resource" "discovery" {
  triggers = {
    cluster         = var.eks_cluster_name
    nad_namespace   = var.nad_namespace
    ext_nad         = var.nad_external_name
    int_nad         = var.nad_internal_name
    selfip_offset   = tostring(var.selfip_host_offset)
    script_hash     = filesha256("${path.module}/scripts/discover-tmm-dataplane.sh")
    discovery_file  = "${path.module}/work/discovery.json"
    kubeconfig_file = "${path.module}/work/kubeconfig"
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      EKS_CLUSTER_NAME      = var.eks_cluster_name
      AWS_REGION            = var.aws_region
      AWS_ACCESS_KEY_ID     = var.aws_access_key_id
      AWS_SECRET_ACCESS_KEY = var.aws_secret_access_key
      AWS_SESSION_TOKEN     = var.aws_session_token
      NAD_NAMESPACE         = var.nad_namespace
      EXT_NAD_NAME          = var.nad_external_name
      INT_NAD_NAME          = var.nad_internal_name
      SELFIP_OFFSET         = tostring(var.selfip_host_offset)
      EXT_PCI_FALLBACK      = var.external_pci_fallback
      INT_PCI_FALLBACK      = var.internal_pci_fallback
      EXT_IF_FALLBACK       = var.external_ifname_fallback
      INT_IF_FALLBACK       = var.internal_ifname_fallback
      SKIP_IFACE_DISCOVERY  = tostring(var.skip_iface_discovery)
      DISCOVERY_OUT         = "${path.module}/work/discovery.json"
      KUBECONFIG_OUT        = "${path.module}/work/kubeconfig"
    }
    command = "bash '${path.module}/scripts/discover-tmm-dataplane.sh'"
  }

  # Best-effort NAD teardown. The SelfIPs + ENIs are destroyed with the node
  # group, so there is nothing to unwind on the AWS side here.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    on_failure  = continue
    command     = <<-EOT
      KC="kubectl --kubeconfig ${self.triggers.kubeconfig_file}"
      for ns in "${self.triggers.nad_namespace}" default; do
        $KC -n "$ns" delete net-attach-def "${self.triggers.ext_nad}" --ignore-not-found 2>/dev/null || true
        $KC -n "$ns" delete net-attach-def "${self.triggers.int_nad}" --ignore-not-found 2>/dev/null || true
      done
    EOT
  }

  lifecycle {
    precondition {
      condition     = var.multus_ready
      error_message = "Multus must be installed before host-device NADs are applied. Wire install-multus.multus_ready into var.multus_ready in the blueprint."
    }
  }
}

# Deferred read: depends_on the discovery resource so Terraform reads the file
# during apply (after the script writes it), not at plan time.
data "local_file" "discovery" {
  filename   = "${path.module}/work/discovery.json"
  depends_on = [null_resource.discovery]
}

locals {
  disc = jsondecode(data.local_file.discovery.content)
}
