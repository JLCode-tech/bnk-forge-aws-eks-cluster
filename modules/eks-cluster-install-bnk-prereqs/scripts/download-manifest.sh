#!/bin/bash
# infrastructure-modules/spk-2.1/far-setup/scripts/download-manifest.sh
# Enhanced version of get-f5-versions.sh for Terraform external data source

set -euo pipefail

# Read inputs from Terraform
eval "$(jq -r '@sh "MANIFEST_VERSION=\(.manifest_version) WORK_DIR=\(.work_dir) CHART_NAME=\(.chart_name) SERVICE_ACCOUNT_KEY_FILE=\(.service_account_key_file // empty)"')"

# Create work directory
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# File paths - all will be detected dynamically
MANIFEST_TAR=""
MANIFEST_DIR=""
MANIFEST_FILE=""

# Function to log messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [download-manifest] $*" >&2
}

# Function to handle errors
error_exit() {
    log "ERROR: $1"
    jq -nc --arg error "$1" '{"success": "false", "error": $error}'
    exit 1
}

log "Starting manifest download for version: $MANIFEST_VERSION"

# Check if FAR credentials are available (via docker config or helm registry login)
if ! command -v helm >/dev/null 2>&1; then
    error_exit "Helm is required but not installed"
fi

# Authenticate to FAR using service account key if provided
# Supports TWO formats for cne_pull_secret:
#   Format A (bare key): base64-encoded JSON service account key
#     → helm registry login -u _json_key_base64 --password-stdin
#   Format B (dockerconfigjson): base64-encoded {"auths":{"repo.f5.com":{"auth":"..."}}}
#     → extract username:password from inner auth field, then helm registry login
if [ -n "${SERVICE_ACCOUNT_KEY_FILE:-}" ] && [ -f "$SERVICE_ACCOUNT_KEY_FILE" ]; then
    RAW_CONTENT=$(cat "$SERVICE_ACCOUNT_KEY_FILE")

    # Detect format: try base64-decode then check for "auths" key
    DECODED_CONTENT=$(echo "$RAW_CONTENT" | base64 -d 2>/dev/null || echo "")
    if echo "$DECODED_CONTENT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'auths' in d" 2>/dev/null; then
        log "Detected dockerconfigjson format — extracting credentials"
        # Extract the auth field from the dockerconfigjson
        INNER_AUTH=$(echo "$DECODED_CONTENT" | python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
auth_b64 = d['auths']['repo.f5.com']['auth']
decoded = base64.b64decode(auth_b64).decode('utf-8')
# Split on first colon only — password may contain colons (JSON key)
idx = decoded.index(':')
username = decoded[:idx]
password = decoded[idx+1:]
print(f'{username}\n{password}')
")
        HELM_USER=$(echo "$INNER_AUTH" | head -1)
        HELM_PASS=$(echo "$INNER_AUTH" | tail -n +2)
        log "Authenticating to FAR as user: $HELM_USER"
        if ! echo "$HELM_PASS" | helm registry login repo.f5.com -u "$HELM_USER" --password-stdin >/dev/null 2>&1; then
            error_exit "Failed to authenticate to FAR (dockerconfigjson format). Check credentials."
        fi
    else
        # Format A: bare service account key — use directly
        log "Authenticating to FAR using bare service account key"
        if ! echo "$RAW_CONTENT" | helm registry login repo.f5.com -u _json_key_base64 --password-stdin >/dev/null 2>&1; then
            error_exit "Failed to authenticate to FAR. Check service account key file: $SERVICE_ACCOUNT_KEY_FILE"
        fi
    fi
    log "FAR authentication successful"
else
    log "No service account key file provided, assuming helm is pre-authenticated"
fi

# Download manifest from FAR
log "Downloading manifest from FAR..."
if ! helm pull "oci://repo.f5.com/release/${CHART_NAME}" --version "$MANIFEST_VERSION" >/dev/null 2>&1; then
    error_exit "Failed to download manifest. Ensure FAR authentication is configured: helm registry login -u _json_key_base64 --password-stdin https://repo.f5.com"
fi

# Find the downloaded tar file (should be the newest .tgz file)
MANIFEST_TAR=$(ls -t *.tgz 2>/dev/null | head -n1)
if [ -z "$MANIFEST_TAR" ] || [ ! -f "$MANIFEST_TAR" ]; then
    error_exit "Could not find downloaded manifest tar file"
fi

log "Manifest downloaded successfully: $MANIFEST_TAR"

# Extract manifest if not already extracted
# Dynamically detect the extracted directory from tar contents
MANIFEST_DIR=$(tar -tf "$MANIFEST_TAR" | head -n1 | cut -d'/' -f1)
if [ -z "$MANIFEST_DIR" ]; then
    error_exit "Could not determine directory name from tar file"
fi

if [ ! -d "$MANIFEST_DIR" ]; then
    log "Extracting manifest..."
    if ! tar xf "$MANIFEST_TAR"; then
        error_exit "Failed to extract manifest archive"
    fi
    log "Manifest extracted to: $MANIFEST_DIR"
else
    log "Manifest already extracted: $MANIFEST_DIR"
fi

# Dynamically find the manifest YAML file
MANIFEST_FILE=$(find "$MANIFEST_DIR" -name "*manifest*.yaml" -type f | head -n1)
if [ -z "$MANIFEST_FILE" ]; then
    # Fallback: try any YAML file in the directory, excluding Chart.yaml
    MANIFEST_FILE=$(find "$MANIFEST_DIR" -name "*.yaml" -type f ! -name "Chart.yaml" | head -n1)
fi

# Verify manifest file exists
if [ ! -f "$MANIFEST_FILE" ]; then
    error_exit "Manifest YAML file not found in directory: $MANIFEST_DIR"
fi

# Validate manifest file structure
log "Validating manifest file structure..."
if ! grep -q "f5_helm_repo:" "$MANIFEST_FILE"; then
    error_exit "Invalid manifest file: missing f5_helm_repo field"
fi

if ! grep -q "helm_charts:" "$MANIFEST_FILE"; then
    error_exit "Invalid manifest file: missing helm_charts section"
fi

if ! grep -q "docker_images:" "$MANIFEST_FILE"; then
    error_exit "Invalid manifest file: missing docker_images section"
fi

# Get absolute path to manifest file
MANIFEST_ABS_PATH="$(pwd)/$MANIFEST_FILE"

log "Manifest validation successful"
log "Manifest file available at: $MANIFEST_ABS_PATH"

# Output success result for Terraform
jq -nc \
    --arg success "true" \
    --arg manifest_file "$MANIFEST_ABS_PATH" \
    --arg manifest_version "$MANIFEST_VERSION" \
    --arg work_dir "$(pwd)" \
    '{
        "success": $success,
        "manifest_file": $manifest_file,
        "manifest_version": $manifest_version,
        "work_dir": $work_dir
    }'

log "Manifest download completed successfully"