#!/bin/bash
# setup_user.sh — User-level setup for NONMEM cross-version comparison
#
# Run once as the non-root user who will run make, AFTER:
#   1. sudo ./setup_root.sh --user $USER has completed
#   2. You have logged out and back in (so docker group takes effect)
#
# Usage:
#   ./setup_user.sh
#
# What this script does:
#   1. Verifies docker is accessible without sudo
#   2. Initializes git submodules (nlmixr2test, Pharmacometrics-Docker)
#   3. Prompts to configure AWS CLI if it is installed but not yet configured
#      (needed for setup-docker-pull.sh; skip if building images locally instead)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "================================================================"
echo " NONMEM compare — user setup"
echo "================================================================"
echo " User:    $USER"
echo " Workdir: $SCRIPT_DIR"
echo " Date:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "================================================================"
echo ""

# ── Step 1: Verify docker access ──────────────────────────────────────────────
echo "Step 1: Verifying Docker access..."
if ! command -v docker &>/dev/null; then
  echo "ERROR: Docker is not installed. Run: sudo ./setup_root.sh --user $USER"
  exit 1
fi
if ! docker info &>/dev/null; then
  echo "ERROR: Cannot connect to Docker daemon."
  echo "  If you just ran setup_root.sh, run: newgrp docker"
  echo "  (or log out and back in) for the docker group to take effect."
  exit 1
fi
echo "  Docker accessible: $(docker --version)"
echo ""

# ── Step 2: Initialize git submodules ─────────────────────────────────────────
echo "Step 2: Initializing git submodules..."
cd "$SCRIPT_DIR"
git submodule update --init --recursive
echo "  Submodules initialized."
echo ""

# ── Step 3: AWS CLI configuration (optional, for ECR image pull) ──────────────
echo "Step 3: Checking AWS CLI configuration..."
if ! command -v aws &>/dev/null; then
  echo "  AWS CLI not installed — skipping."
  echo "  (Install with: sudo ./setup_root.sh --user $USER --with-awscli)"
else
  AWS_CONFIGURED=0
  if [[ -f "$HOME/.aws/credentials" ]] || \
     { [[ -f "$HOME/.aws/config" ]] && grep -q 'aws_access_key_id\|role_arn\|credential_process' "$HOME/.aws/config" 2>/dev/null; }; then
    AWS_CONFIGURED=1
  fi

  if [[ "$AWS_CONFIGURED" -eq 1 ]]; then
    echo "  AWS CLI already configured."
  else
    echo "  AWS CLI is installed but not configured."
    echo "  AWS credentials are needed to pull Docker images from ECR."
    echo ""
    read -r -p "  Configure AWS CLI now? [y/N] " REPLY
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
      aws configure
    else
      echo "  Skipping. Run 'aws configure' later, or build images locally with:"
      echo "    ./setup-docker-build.sh"
    fi
  fi
fi
echo ""

# ── Done ──────────────────────────────────────────────────────────────────────
echo "================================================================"
echo " User setup complete."
echo ""
echo " Next: get Docker images using one of:"
echo "   ./setup-docker-pull.sh          # Pull from ECR (requires AWS credentials)"
echo "   ./setup-docker-build.sh         # Build from source (requires NONMEM files)"
echo ""
echo " Then run the comparison from this directory:"
echo "   make -j\$(nproc)"
echo "================================================================"
