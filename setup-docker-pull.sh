#!/bin/bash
# setup-docker-pull.sh — Pull humanpredictions/nonmem Docker images from ECR
#
# Usage:
#   ./setup-docker-pull.sh [--registry REGISTRY] [--region REGION]
#                          [--jobs N] [--arch ARCH]
#
# This script authenticates to AWS ECR and pulls all humanpredictions/nonmem
# images for the current host architecture that are known to work correctly.
# Broken image combinations (e.g. NONMEM 7.2.0/7.3.0 + gfortran >= 10) are
# excluded.
#
# NOTE: NONMEM Docker images are not publicly distributable due to the NONMEM
# license. Access requires AWS credentials with read access to the ECR registry.
# Contact Human Predictions LLC for access.
#
# Prerequisites:
#   - AWS CLI installed and configured (run setup_root.sh --with-awscli, then
#     aws configure, or use an IAM role/instance profile)
#   - Docker installed and running
#   - Sufficient disk space:
#       amd64: ~500 GB for all images
#       arm64: ~50 GB for all images (20 tags: 7.5.1/7.6.0, Ubuntu 22.04/24.04)

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
ECR_REGISTRY="${ECR_REGISTRY:-700534259652.dkr.ecr.us-east-1.amazonaws.com}"
LOCAL_REPO="humanpredictions/nonmem"
REGION="${REGION:-us-east-1}"
JOBS="${JOBS:-4}"

# Detect host architecture in Docker naming convention
detect_arch() {
  case "$(uname -m)" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l)  echo "arm"   ;;
    *)       echo "$(uname -m)" ;;
  esac
}
ARCH="${ARCH:-$(detect_arch)}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --registry URL    ECR registry URL (default: $ECR_REGISTRY)
  --region REGION   AWS region (default: $REGION)
  --jobs N          Parallel pulls (default: $JOBS)
  --arch ARCH       Target architecture (default: auto-detected: $ARCH)
  -h, --help        Show this help
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) ECR_REGISTRY="$2"; shift 2 ;;
    --region)   REGION="$2";       shift 2 ;;
    --jobs)     JOBS="$2";         shift 2 ;;
    --arch)     ARCH="$2";         shift 2 ;;
    -h|--help)  usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

echo "================================================================"
echo " NONMEM Docker image pull from ECR"
echo "================================================================"
echo " Registry:     $ECR_REGISTRY"
echo " Region:       $REGION"
echo " Architecture: $ARCH"
echo " Parallel:     $JOBS"
echo " Date:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "================================================================"
echo ""

# ── Authenticate to ECR ───────────────────────────────────────────────────────
echo "Authenticating to ECR..."
if ! command -v aws &>/dev/null; then
  echo "ERROR: AWS CLI is not installed."
  echo "  Run: sudo ./setup_root.sh --user $USER --with-awscli"
  exit 1
fi
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
echo "Authenticated."
echo ""

# ── Known-working tags per architecture ──────────────────────────────────────
# Excluded from amd64:
#   - 7.2.0/7.3.0 + gfortran >= 10   (-fno-common linker failure)
#   - 7.4.x/7.5.0 + gfortran >= 10   (build failure)
#   - 7.5.1/7.6.0 + gfortran 4.4     (-ffpe-summary=none not supported)
#   - 7.5.1/7.6.0 + gfortran 13/14   (ADVAN13 SIGSEGV — see known-issues in README)
#
# arm64 supports only NONMEM >= 7.5.1 on Ubuntu >= 22.04.
# arm64 gfortran 13/14 tags are included with a warning (see below).

declare -A ARCH_TAGS

ARCH_TAGS[amd64]="
  7.2.0-ubuntu14.04-gfortran4.4-amd64
  7.2.0-ubuntu14.04-gfortran4.6-amd64
  7.2.0-ubuntu14.04-gfortran4.7-amd64
  7.2.0-ubuntu14.04-gfortran4.8-amd64
  7.2.0-ubuntu16.04-gfortran4.7-amd64
  7.2.0-ubuntu16.04-gfortran4.8-amd64
  7.2.0-ubuntu16.04-gfortran4.9-amd64
  7.2.0-ubuntu16.04-gfortran5-amd64
  7.2.0-ubuntu18.04-gfortran4.8-amd64
  7.2.0-ubuntu18.04-gfortran5-amd64
  7.2.0-ubuntu18.04-gfortran6-amd64
  7.2.0-ubuntu18.04-gfortran7-amd64
  7.2.0-ubuntu18.04-gfortran8-amd64
  7.2.0-ubuntu20.04-gfortran7-amd64
  7.2.0-ubuntu20.04-gfortran8-amd64
  7.2.0-ubuntu20.04-gfortran9-amd64
  7.2.0-ubuntu22.04-gfortran9-amd64
  7.2.0-ubuntu24.04-gfortran9-amd64
  7.3.0-ubuntu14.04-gfortran4.4-amd64
  7.3.0-ubuntu14.04-gfortran4.6-amd64
  7.3.0-ubuntu14.04-gfortran4.7-amd64
  7.3.0-ubuntu14.04-gfortran4.8-amd64
  7.3.0-ubuntu16.04-gfortran4.7-amd64
  7.3.0-ubuntu16.04-gfortran4.8-amd64
  7.3.0-ubuntu16.04-gfortran4.9-amd64
  7.3.0-ubuntu16.04-gfortran5-amd64
  7.3.0-ubuntu18.04-gfortran4.8-amd64
  7.3.0-ubuntu18.04-gfortran5-amd64
  7.3.0-ubuntu18.04-gfortran6-amd64
  7.3.0-ubuntu18.04-gfortran7-amd64
  7.3.0-ubuntu18.04-gfortran8-amd64
  7.3.0-ubuntu20.04-gfortran7-amd64
  7.3.0-ubuntu20.04-gfortran8-amd64
  7.3.0-ubuntu20.04-gfortran9-amd64
  7.3.0-ubuntu22.04-gfortran9-amd64
  7.3.0-ubuntu24.04-gfortran9-amd64
  7.4.1-ubuntu14.04-gfortran4.4-amd64
  7.4.1-ubuntu14.04-gfortran4.6-amd64
  7.4.1-ubuntu14.04-gfortran4.7-amd64
  7.4.1-ubuntu14.04-gfortran4.8-amd64
  7.4.1-ubuntu16.04-gfortran4.7-amd64
  7.4.1-ubuntu16.04-gfortran4.8-amd64
  7.4.1-ubuntu16.04-gfortran4.9-amd64
  7.4.1-ubuntu16.04-gfortran5-amd64
  7.4.1-ubuntu18.04-gfortran4.8-amd64
  7.4.1-ubuntu18.04-gfortran5-amd64
  7.4.1-ubuntu18.04-gfortran6-amd64
  7.4.1-ubuntu18.04-gfortran7-amd64
  7.4.1-ubuntu18.04-gfortran8-amd64
  7.4.1-ubuntu20.04-gfortran7-amd64
  7.4.1-ubuntu20.04-gfortran8-amd64
  7.4.1-ubuntu20.04-gfortran9-amd64
  7.4.1-ubuntu22.04-gfortran9-amd64
  7.4.1-ubuntu24.04-gfortran9-amd64
  7.4.2-ubuntu14.04-gfortran4.4-amd64
  7.4.2-ubuntu14.04-gfortran4.6-amd64
  7.4.2-ubuntu14.04-gfortran4.7-amd64
  7.4.2-ubuntu14.04-gfortran4.8-amd64
  7.4.2-ubuntu16.04-gfortran4.7-amd64
  7.4.2-ubuntu16.04-gfortran4.8-amd64
  7.4.2-ubuntu16.04-gfortran4.9-amd64
  7.4.2-ubuntu16.04-gfortran5-amd64
  7.4.2-ubuntu18.04-gfortran4.8-amd64
  7.4.2-ubuntu18.04-gfortran5-amd64
  7.4.2-ubuntu18.04-gfortran6-amd64
  7.4.2-ubuntu18.04-gfortran7-amd64
  7.4.2-ubuntu18.04-gfortran8-amd64
  7.4.2-ubuntu20.04-gfortran7-amd64
  7.4.2-ubuntu20.04-gfortran8-amd64
  7.4.2-ubuntu20.04-gfortran9-amd64
  7.4.2-ubuntu22.04-gfortran9-amd64
  7.4.2-ubuntu24.04-gfortran9-amd64
  7.4.3-ubuntu14.04-gfortran4.4-amd64
  7.4.3-ubuntu14.04-gfortran4.6-amd64
  7.4.3-ubuntu14.04-gfortran4.7-amd64
  7.4.3-ubuntu14.04-gfortran4.8-amd64
  7.4.3-ubuntu16.04-gfortran4.7-amd64
  7.4.3-ubuntu16.04-gfortran4.8-amd64
  7.4.3-ubuntu16.04-gfortran4.9-amd64
  7.4.3-ubuntu16.04-gfortran5-amd64
  7.4.3-ubuntu18.04-gfortran4.8-amd64
  7.4.3-ubuntu18.04-gfortran5-amd64
  7.4.3-ubuntu18.04-gfortran6-amd64
  7.4.3-ubuntu18.04-gfortran7-amd64
  7.4.3-ubuntu18.04-gfortran8-amd64
  7.4.3-ubuntu20.04-gfortran7-amd64
  7.4.3-ubuntu20.04-gfortran8-amd64
  7.4.3-ubuntu20.04-gfortran9-amd64
  7.4.3-ubuntu22.04-gfortran9-amd64
  7.4.3-ubuntu24.04-gfortran9-amd64
  7.4.4-ubuntu14.04-gfortran4.4-amd64
  7.4.4-ubuntu14.04-gfortran4.6-amd64
  7.4.4-ubuntu14.04-gfortran4.7-amd64
  7.4.4-ubuntu14.04-gfortran4.8-amd64
  7.4.4-ubuntu16.04-gfortran4.7-amd64
  7.4.4-ubuntu16.04-gfortran4.8-amd64
  7.4.4-ubuntu16.04-gfortran4.9-amd64
  7.4.4-ubuntu16.04-gfortran5-amd64
  7.4.4-ubuntu18.04-gfortran4.8-amd64
  7.4.4-ubuntu18.04-gfortran5-amd64
  7.4.4-ubuntu18.04-gfortran6-amd64
  7.4.4-ubuntu18.04-gfortran7-amd64
  7.4.4-ubuntu18.04-gfortran8-amd64
  7.4.4-ubuntu20.04-gfortran7-amd64
  7.4.4-ubuntu20.04-gfortran8-amd64
  7.4.4-ubuntu20.04-gfortran9-amd64
  7.4.4-ubuntu22.04-gfortran9-amd64
  7.4.4-ubuntu24.04-gfortran9-amd64
  7.5.0-ubuntu14.04-gfortran4.4-amd64
  7.5.0-ubuntu14.04-gfortran4.6-amd64
  7.5.0-ubuntu14.04-gfortran4.7-amd64
  7.5.0-ubuntu14.04-gfortran4.8-amd64
  7.5.0-ubuntu16.04-gfortran4.7-amd64
  7.5.0-ubuntu16.04-gfortran4.8-amd64
  7.5.0-ubuntu16.04-gfortran4.9-amd64
  7.5.0-ubuntu16.04-gfortran5-amd64
  7.5.0-ubuntu18.04-gfortran4.8-amd64
  7.5.0-ubuntu18.04-gfortran5-amd64
  7.5.0-ubuntu18.04-gfortran6-amd64
  7.5.0-ubuntu18.04-gfortran7-amd64
  7.5.0-ubuntu18.04-gfortran8-amd64
  7.5.0-ubuntu20.04-gfortran7-amd64
  7.5.0-ubuntu20.04-gfortran8-amd64
  7.5.0-ubuntu20.04-gfortran9-amd64
  7.5.0-ubuntu22.04-gfortran9-amd64
  7.5.0-ubuntu24.04-gfortran9-amd64
  7.5.1-ubuntu14.04-gfortran4.6-amd64
  7.5.1-ubuntu14.04-gfortran4.7-amd64
  7.5.1-ubuntu14.04-gfortran4.8-amd64
  7.5.1-ubuntu16.04-gfortran4.7-amd64
  7.5.1-ubuntu16.04-gfortran4.8-amd64
  7.5.1-ubuntu16.04-gfortran4.9-amd64
  7.5.1-ubuntu16.04-gfortran5-amd64
  7.5.1-ubuntu18.04-gfortran4.8-amd64
  7.5.1-ubuntu18.04-gfortran5-amd64
  7.5.1-ubuntu18.04-gfortran6-amd64
  7.5.1-ubuntu18.04-gfortran7-amd64
  7.5.1-ubuntu18.04-gfortran8-amd64
  7.5.1-ubuntu20.04-gfortran7-amd64
  7.5.1-ubuntu20.04-gfortran8-amd64
  7.5.1-ubuntu20.04-gfortran9-amd64
  7.5.1-ubuntu20.04-gfortran10-amd64
  7.5.1-ubuntu22.04-gfortran9-amd64
  7.5.1-ubuntu22.04-gfortran10-amd64
  7.5.1-ubuntu22.04-gfortran11-amd64
  7.5.1-ubuntu22.04-gfortran12-amd64
  7.5.1-ubuntu24.04-gfortran9-amd64
  7.5.1-ubuntu24.04-gfortran10-amd64
  7.5.1-ubuntu24.04-gfortran11-amd64
  7.5.1-ubuntu24.04-gfortran12-amd64
  7.6.0-ubuntu14.04-gfortran4.6-amd64
  7.6.0-ubuntu14.04-gfortran4.7-amd64
  7.6.0-ubuntu14.04-gfortran4.8-amd64
  7.6.0-ubuntu16.04-gfortran4.7-amd64
  7.6.0-ubuntu16.04-gfortran4.8-amd64
  7.6.0-ubuntu16.04-gfortran4.9-amd64
  7.6.0-ubuntu16.04-gfortran5-amd64
  7.6.0-ubuntu18.04-gfortran4.8-amd64
  7.6.0-ubuntu18.04-gfortran5-amd64
  7.6.0-ubuntu18.04-gfortran6-amd64
  7.6.0-ubuntu18.04-gfortran7-amd64
  7.6.0-ubuntu18.04-gfortran8-amd64
  7.6.0-ubuntu20.04-gfortran7-amd64
  7.6.0-ubuntu20.04-gfortran8-amd64
  7.6.0-ubuntu20.04-gfortran9-amd64
  7.6.0-ubuntu20.04-gfortran10-amd64
  7.6.0-ubuntu22.04-gfortran9-amd64
  7.6.0-ubuntu22.04-gfortran10-amd64
  7.6.0-ubuntu22.04-gfortran11-amd64
  7.6.0-ubuntu22.04-gfortran12-amd64
  7.6.0-ubuntu24.04-gfortran9-amd64
  7.6.0-ubuntu24.04-gfortran10-amd64
  7.6.0-ubuntu24.04-gfortran11-amd64
  7.6.0-ubuntu24.04-gfortran12-amd64
"

# arm64: NONMEM 7.5.1/7.6.0 on Ubuntu 22.04/24.04 only.
# WARNING: gfortran 13/14 tags are included but cause SIGSEGV crashes on
# specific ADVAN13 models (runODE063, 068, 069, 070). See README known issues.
ARCH_TAGS[arm64]="
  7.5.1-ubuntu22.04-gfortran9-arm64
  7.5.1-ubuntu22.04-gfortran10-arm64
  7.5.1-ubuntu22.04-gfortran11-arm64
  7.5.1-ubuntu22.04-gfortran12-arm64
  7.5.1-ubuntu24.04-gfortran9-arm64
  7.5.1-ubuntu24.04-gfortran10-arm64
  7.5.1-ubuntu24.04-gfortran11-arm64
  7.5.1-ubuntu24.04-gfortran12-arm64
  7.5.1-ubuntu24.04-gfortran13-arm64
  7.5.1-ubuntu24.04-gfortran14-arm64
  7.6.0-ubuntu22.04-gfortran9-arm64
  7.6.0-ubuntu22.04-gfortran10-arm64
  7.6.0-ubuntu22.04-gfortran11-arm64
  7.6.0-ubuntu22.04-gfortran12-arm64
  7.6.0-ubuntu24.04-gfortran9-arm64
  7.6.0-ubuntu24.04-gfortran10-arm64
  7.6.0-ubuntu24.04-gfortran11-arm64
  7.6.0-ubuntu24.04-gfortran12-arm64
  7.6.0-ubuntu24.04-gfortran13-arm64
  7.6.0-ubuntu24.04-gfortran14-arm64
"

if [[ -z "${ARCH_TAGS[$ARCH]+x}" ]]; then
  echo "ERROR: No known-working image list for architecture '$ARCH'."
  echo "Supported architectures: ${!ARCH_TAGS[*]}"
  exit 1
fi

# Warn about gfortran 13/14 on arm64 before pulling
if [[ "$ARCH" == "arm64" ]]; then
  echo "NOTE: The arm64 image list includes gfortran 13 and 14 tags."
  echo "  These are known to cause SIGSEGV crashes on specific ADVAN13 models"
  echo "  (oral 2-compartment ODE models: runODE063, runODE068, runODE069, runODE070)."
  echo "  All other models run correctly. See README for details."
  echo ""
fi

# Convert to array
readarray -t TAGS <<< "$(echo "${ARCH_TAGS[$ARCH]}" | tr -s '[:space:]' '\n' | grep -v '^$')"
TOTAL=${#TAGS[@]}
echo "Pulling $TOTAL known-working images for $ARCH ($JOBS in parallel)..."
echo ""

# ── Pull function ─────────────────────────────────────────────────────────────
pull_image() {
  local tag="$1"
  local ecr_image="$ECR_REGISTRY/$LOCAL_REPO:$tag"
  local local_image="$LOCAL_REPO:$tag"

  if docker image inspect "$local_image" > /dev/null 2>&1; then
    echo "  SKIP (already present): $tag"
    return 0
  fi

  if docker pull "$ecr_image" > /dev/null 2>&1; then
    docker tag "$ecr_image" "$local_image" 2>/dev/null || true
    echo "  OK: $tag"
  else
    echo "  FAILED: $tag" >&2
    return 1
  fi
}

export -f pull_image
export ECR_REGISTRY LOCAL_REPO

printf '%s\n' "${TAGS[@]}" \
  | xargs -P "$JOBS" -I{} bash -c 'pull_image "$@"' _ {}

echo ""
PRESENT=$(docker images --format "{{.Tag}}" "$LOCAL_REPO" | grep -- "-${ARCH}$" | wc -l)
echo "Done. $PRESENT $ARCH images now present locally as $LOCAL_REPO:<tag>"
echo ""
echo "Run the comparison from the repo root:"
echo "  make -j\$(nproc)"
