#!/usr/bin/env bash
# =============================================================================
# discover-tmm-dataplane.sh — host-device TMM data-plane preparation
# =============================================================================
# Ports awsbnkctl phase16 (TMM node label) + phase17 (secondary-ENI SelfIP
# assignment) + phase17c (iface-discovery: MAC -> ifname -> PCI) + phase20 (NADs)
# into a single imperative step that Terraform cannot express natively (the
# secondary ENIs are created by the hp-nodes bootstrap, so Terraform doesn't own
# them; there is no native resource for assigning a secondary private IP to an
# unmanaged ENI).
#
# Inputs (environment):
#   EKS_CLUSTER_NAME, AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
#   AWS_SESSION_TOKEN (optional), NAD_NAMESPACE, EXT_NAD_NAME, INT_NAD_NAME,
#   DISCOVERY_OUT (path to write the result JSON), KUBECONFIG_OUT (path),
#   SELFIP_OFFSET (default 240), EXT_PCI_FALLBACK / INT_PCI_FALLBACK,
#   EXT_IF_FALLBACK / INT_IF_FALLBACK, SKIP_IFACE_DISCOVERY (default false).
#
# Effects:
#   1. Labels the single role=bnk node app=f5-tmm and resolves its instance-id.
#   2. Finds the two tagged secondary ENIs (f5-bnk:tmm-role=external|internal),
#      assigns SelfIP <subnet>.240 to each (idempotent, --allow-reassignment).
#   3. Runs a privileged probe pod on the node to map ENI MAC -> Linux ifname +
#      PCI bus id (BEFORE any TMM pod claims the ENI into its netns).
#   4. Applies host-device NADs (pciBusID) into NAD_NAMESPACE and `default`.
#   5. Writes the discovered facts to DISCOVERY_OUT for Terraform to surface as
#      module outputs (consumed by cneinstall).
#
# Idempotent: re-running re-labels, re-assigns (skips if present), and re-applies
# (kubectl apply). If a TMM pod is already Running the host-netns probe can no
# longer see the moved ENIs, so on the re-run path the deterministic fallback
# (device-index ens8/ens7 -> 0000:00:08.0/0000:00:07.0) is used and the result
# JSON is preserved from the prior run when still present.
set -euo pipefail

log() { echo "[tmm-discovery] $*" >&2; }

: "${EKS_CLUSTER_NAME:?}" "${AWS_REGION:?}" "${NAD_NAMESPACE:?}"
: "${EXT_NAD_NAME:?}" "${INT_NAD_NAME:?}" "${DISCOVERY_OUT:?}" "${KUBECONFIG_OUT:?}"
SELFIP_OFFSET="${SELFIP_OFFSET:-240}"
EXT_PCI_FALLBACK="${EXT_PCI_FALLBACK:-0000:00:08.0}"
INT_PCI_FALLBACK="${INT_PCI_FALLBACK:-0000:00:07.0}"
EXT_IF_FALLBACK="${EXT_IF_FALLBACK:-ens8}"
INT_IF_FALLBACK="${INT_IF_FALLBACK:-ens7}"
SKIP_IFACE_DISCOVERY="${SKIP_IFACE_DISCOVERY:-false}"

export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

# Fresh exec-auth kubeconfig — sidesteps the F12 stale-token (the EKS auth token
# baked into a module's stored kubeconfig expires ~15 min and 401s on re-runs).
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" \
  --kubeconfig "$KUBECONFIG_OUT" >&2
KC="kubectl --kubeconfig $KUBECONFIG_OUT"

# ---- phase16: select + label the single TMM node ----------------------------
NODE="$($KC get nodes -l role=bnk -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$NODE" ]; then
  log "FATAL: no node with label role=bnk — is the HP node group ACTIVE?"
  exit 1
fi
PROVIDER_ID="$($KC get node "$NODE" -o jsonpath='{.spec.providerID}')"
INSTANCE_ID="${PROVIDER_ID##*/}"
log "TMM node=$NODE instance=$INSTANCE_ID"
$KC label node "$NODE" app=f5-tmm --overwrite >&2

# ---- phase17: locate the tagged secondary ENIs ------------------------------
describe_eni() { # $1=role -> "eniid<TAB>mac<TAB>subnetid"
  aws ec2 describe-network-interfaces \
    --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
              "Name=tag:f5-bnk:tmm-role,Values=$1" \
    --query 'NetworkInterfaces[0].[NetworkInterfaceId,MacAddress,SubnetId]' \
    --output text
}
IFS=$'\t' read -r EXT_ENI EXT_MAC EXT_SUBNET <<EOF
$(describe_eni external)
EOF
IFS=$'\t' read -r INT_ENI INT_MAC INT_SUBNET <<EOF
$(describe_eni internal)
EOF
for v in "$EXT_ENI" "$INT_ENI"; do
  if [ -z "$v" ] || [ "$v" = "None" ]; then
    log "FATAL: could not find both TMM secondary ENIs on $INSTANCE_ID (ext=$EXT_ENI int=$INT_ENI)"
    exit 1
  fi
done
EXT_MAC="$(printf '%s' "$EXT_MAC" | tr 'A-Z' 'a-z')"
INT_MAC="$(printf '%s' "$INT_MAC" | tr 'A-Z' 'a-z')"
log "external eni=$EXT_ENI mac=$EXT_MAC subnet=$EXT_SUBNET"
log "internal eni=$INT_ENI mac=$INT_MAC subnet=$INT_SUBNET"

subnet_field() { # $1=subnet $2=jmespath
  aws ec2 describe-subnets --subnet-ids "$1" --query "Subnets[0].$2" --output text
}
EXT_CIDR="$(subnet_field "$EXT_SUBNET" CidrBlock)"
INT_CIDR="$(subnet_field "$INT_SUBNET" CidrBlock)"
TMM_AZ="$(subnet_field "$EXT_SUBNET" AvailabilityZone)"
PREFIX="${EXT_CIDR#*/}"

# SelfIP = <subnet network /24>.<offset>. awsbnkctl restricts SelfIP derivation
# to /24 subnets (DeriveSelfIP); the HP TMM subnets are /24 by default.
selfip_for() { printf '%s.%s' "$(printf '%s' "${1%/*}" | cut -d. -f1-3)" "$SELFIP_OFFSET"; }
EXT_SELFIP="$(selfip_for "$EXT_CIDR")"
INT_SELFIP="$(selfip_for "$INT_CIDR")"

assign_selfip() { # $1=eni $2=ip
  if aws ec2 describe-network-interfaces --network-interface-ids "$1" \
       --query 'NetworkInterfaces[0].PrivateIpAddresses[].PrivateIpAddress' \
       --output text | tr '\t' '\n' | grep -qx "$2"; then
    log "SelfIP $2 already assigned to $1"
    return
  fi
  aws ec2 assign-private-ip-addresses --network-interface-id "$1" \
    --private-ip-addresses "$2" --allow-reassignment >&2
  log "assigned SelfIP $2 to $1 (per F5 Multi-AZ PDF p.9)"
}
assign_selfip "$EXT_ENI" "$EXT_SELFIP"
assign_selfip "$INT_ENI" "$INT_SELFIP"

# ---- phase17c: iface-discovery (MAC -> ifname -> PCI) ------------------------
EXT_IF="$EXT_IF_FALLBACK"; EXT_PCI="$EXT_PCI_FALLBACK"
INT_IF="$INT_IF_FALLBACK"; INT_PCI="$INT_PCI_FALLBACK"

tmm_running() {
  local n
  n="$($KC -n "$NAD_NAMESPACE" get pods -l app=f5-tmm \
        --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')"
  [ "${n:-0}" -gt 0 ]
}

if [ "$SKIP_IFACE_DISCOVERY" = "true" ]; then
  log "iface-discovery skipped (SKIP_IFACE_DISCOVERY=true) — using deterministic fallback"
elif tmm_running; then
  log "a TMM pod is already Running — ENIs claimed into its netns; using deterministic fallback"
else
  POD=iface-discovery
  $KC -n kube-system delete pod "$POD" --ignore-not-found >&2 2>/dev/null || true
  # The probe emits one line per netdev: "<mac> <ifname> <pci>". Static YAML
  # (no Terraform interpolation) so the $() inside the probe command is safe.
  cat <<'YAML' | sed "s|__NODE__|$NODE|" | $KC apply -f - >&2
apiVersion: v1
kind: Pod
metadata:
  name: iface-discovery
  namespace: kube-system
spec:
  nodeName: __NODE__
  hostNetwork: true
  restartPolicy: Never
  tolerations:
    - operator: Exists
  containers:
    - name: probe
      image: alpine:3.20
      securityContext:
        privileged: true
      volumeMounts:
        - name: hostsys
          mountPath: /host/sys
          readOnly: true
      command:
        - /bin/sh
        - -c
        - |
          for d in /host/sys/class/net/*; do
            i="${d##*/}"
            [ -e "$d/device" ] || continue
            m="$(cat "$d/address" 2>/dev/null)" || continue
            [ -z "$m" ] && continue
            p="$(basename "$(readlink -f "$d/device")")" || continue
            [ -z "$p" ] && continue
            echo "$m $i $p"
          done
  volumes:
    - name: hostsys
      hostPath:
        path: /sys
YAML
  ok=""
  for _ in $(seq 1 36); do
    phase="$($KC -n kube-system get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Succeeded) ok="yes"; break ;;
      Failed) log "iface-discovery pod Failed — using deterministic fallback"; break ;;
    esac
    sleep 5
  done
  if [ -n "$ok" ]; then
    MAP="$($KC -n kube-system logs "$POD" 2>/dev/null || true)"
    log "iface map:"; printf '%s\n' "$MAP" >&2
    lookup() { printf '%s\n' "$MAP" | awk -v mac="$1" -v col="$2" 'tolower($1)==mac{print $col; exit}'; }
    e_if="$(lookup "$EXT_MAC" 2)"; e_pci="$(lookup "$EXT_MAC" 3)"
    i_if="$(lookup "$INT_MAC" 2)"; i_pci="$(lookup "$INT_MAC" 3)"
    [ -n "$e_if" ] && EXT_IF="$e_if"; [ -n "$e_pci" ] && EXT_PCI="$e_pci"
    [ -n "$i_if" ] && INT_IF="$i_if"; [ -n "$i_pci" ] && INT_PCI="$i_pci"
  fi
  $KC -n kube-system delete pod "$POD" --ignore-not-found >&2 2>/dev/null || true
fi
log "external if=$EXT_IF pci=$EXT_PCI ; internal if=$INT_IF pci=$INT_PCI"

# ---- phase20: apply host-device NADs in NAD_NAMESPACE and default -----------
apply_nad() { # $1=ns $2=name $3=netname $4=pci
  cat <<YAML | $KC apply -f - >&2
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: $2
  namespace: $1
  labels:
    app.kubernetes.io/managed-by: bnk-forge-eks-cluster-install-tmm-nads
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "$3",
      "type": "host-device",
      "pciBusID": "$4"
    }
YAML
}
for ns in "$NAD_NAMESPACE" default; do
  apply_nad "$ns" "$EXT_NAD_NAME" external-network "$EXT_PCI"
  apply_nad "$ns" "$INT_NAD_NAME" internal-network "$INT_PCI"
done
log "applied host-device NADs ($EXT_NAD_NAME/$INT_NAD_NAME) in $NAD_NAMESPACE + default"

# ---- emit discovery JSON for Terraform to surface as outputs ----------------
jq -n \
  --arg tmm_node "$NODE" --arg tmm_instance_id "$INSTANCE_ID" --arg tmm_az "$TMM_AZ" \
  --arg external_eni "$EXT_ENI" --arg internal_eni "$INT_ENI" \
  --arg external_ifname "$EXT_IF" --arg internal_ifname "$INT_IF" \
  --arg external_pci "$EXT_PCI" --arg internal_pci "$INT_PCI" \
  --arg external_selfip "$EXT_SELFIP" --arg internal_selfip "$INT_SELFIP" \
  --arg selfip_prefixlen "$PREFIX" \
  --arg external_subnet_id "$EXT_SUBNET" --arg internal_subnet_id "$INT_SUBNET" \
  --arg external_subnet_cidr "$EXT_CIDR" --arg internal_subnet_cidr "$INT_CIDR" \
  '{tmm_node:$tmm_node, tmm_instance_id:$tmm_instance_id, tmm_az:$tmm_az,
    external_eni:$external_eni, internal_eni:$internal_eni,
    external_ifname:$external_ifname, internal_ifname:$internal_ifname,
    external_pci:$external_pci, internal_pci:$internal_pci,
    external_selfip:$external_selfip, internal_selfip:$internal_selfip,
    selfip_prefixlen:($selfip_prefixlen|tonumber),
    external_subnet_id:$external_subnet_id, internal_subnet_id:$internal_subnet_id,
    external_subnet_cidr:$external_subnet_cidr, internal_subnet_cidr:$internal_subnet_cidr}' \
  > "$DISCOVERY_OUT"
log "wrote $DISCOVERY_OUT:"
cat "$DISCOVERY_OUT" >&2
