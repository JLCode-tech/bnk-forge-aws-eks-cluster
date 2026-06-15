# =============================================================================
# NAD identity
# =============================================================================

output "nad_external_name" {
  description = "External host-device NAD name. Use as cneinstall network_attachments[0] (→ TMM trunk 1.1 / ext-vlan)."
  value       = var.nad_external_name
}

output "nad_internal_name" {
  description = "Internal host-device NAD name. Use as cneinstall network_attachments[1] (→ TMM trunk 1.2 / int-vlan)."
  value       = var.nad_internal_name
}

output "nad_namespace" {
  description = "Namespace where the NADs were created (also applied to `default`)."
  value       = var.nad_namespace
}

# =============================================================================
# Discovered host-device facts (consumed by cneinstall)
# =============================================================================

output "external_pci" {
  description = "PCI bus id of the external TMM ENI (host-device NAD pciBusID + CNEInstance PCIDEVICE_INTEL_COM_<ifname> env)."
  value       = local.disc.external_pci
}

output "internal_pci" {
  description = "PCI bus id of the internal TMM ENI."
  value       = local.disc.internal_pci
}

output "external_ifname" {
  description = "Linux ifname of the external TMM ENI (CNEInstance CLOUD_HOST_DEVICE_NAME / ROBIN_VFIO_RESOURCE_1)."
  value       = local.disc.external_ifname
}

output "internal_ifname" {
  description = "Linux ifname of the internal TMM ENI (ROBIN_VFIO_RESOURCE_2)."
  value       = local.disc.internal_ifname
}

output "external_selfip" {
  description = "External TMM SelfIP (<subnet>.240), assigned as a secondary IP on the ENI and announced by the ext-vlan F5SPKVlan."
  value       = local.disc.external_selfip
}

output "internal_selfip" {
  description = "Internal TMM SelfIP, announced by the int-vlan F5SPKVlan."
  value       = local.disc.internal_selfip
}

output "selfip_prefixlen" {
  description = "Prefix length of the TMM SelfIPs (subnet prefix; 24 for the default /24 TMM subnets)."
  value       = local.disc.selfip_prefixlen
}

output "tmm_az" {
  description = "Availability zone of the single TMM node — used to scope cneinstall's single-AZ cloud-network-mapping."
  value       = local.disc.tmm_az
}

output "tmm_node" {
  description = "Kubernetes node name of the single TMM node (labeled app=f5-tmm)."
  value       = local.disc.tmm_node
}

output "external_subnet_id" {
  description = "Subnet id of the external TMM ENI."
  value       = local.disc.external_subnet_id
}

output "internal_subnet_id" {
  description = "Subnet id of the internal TMM ENI."
  value       = local.disc.internal_subnet_id
}

output "external_subnet_cidr" {
  description = "CIDR of the external TMM subnet."
  value       = local.disc.external_subnet_cidr
}

output "internal_subnet_cidr" {
  description = "CIDR of the internal TMM subnet."
  value       = local.disc.internal_subnet_cidr
}

# =============================================================================
# Gate
# =============================================================================

output "nads_applied" {
  description = "Gate output — true once the discovery script has assigned SelfIPs and applied both host-device NADs. cneinstall depends on this before rendering the CNEInstance CR."
  value       = true

  depends_on = [
    null_resource.discovery,
    data.local_file.discovery,
  ]
}
