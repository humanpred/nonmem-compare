#!/bin/bash
# setup_root.sh — System-level setup for NONMEM cross-version comparison
#
# Run once as root (or with sudo) on a fresh Ubuntu 24.04 LTS system.
#
# Usage:
#   sudo ./setup_root.sh --user USERNAME [--with-awscli]
#
# What this script does:
#   1. Installs Docker CE (official Docker apt repository)
#   2. Adds USERNAME to the docker group
#   3. Installs build tools: make, git, unzip, curl
#   4. Optionally installs AWS CLI v2 (required only for ECR image pull)
#
# After running:
#   Log out and back in (or run: newgrp docker) for the docker group to take effect.
#   Then run ./setup_user.sh as the target user.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
USERNAME=""
WITH_AWSCLI=0

usage() {
  cat <<EOF
Usage: sudo $0 --user USERNAME [--with-awscli]

Required:
  --user USERNAME   Linux user to add to the docker group

Options:
  --with-awscli     Also install AWS CLI v2 (needed for ECR image pull)
  -h, --help        Show this help
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)       USERNAME="$2"; shift 2 ;;
    --with-awscli) WITH_AWSCLI=1; shift ;;
    -h|--help)    usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$USERNAME" ]]; then
  echo "ERROR: --user USERNAME is required."
  usage
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: This script must be run as root or with sudo."
  exit 1
fi

echo "================================================================"
echo " NONMEM compare — root system setup"
echo "================================================================"
echo " Target user: $USERNAME"
echo " AWS CLI:     $([ "$WITH_AWSCLI" -eq 1 ] && echo yes || echo no)"
echo " Date:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "================================================================"
echo ""

# ── Step 1: System packages ───────────────────────────────────────────────────
echo "Step 1: Installing system packages..."
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  git \
  make \
  unzip
echo ""

# ── Step 2: Docker CE ─────────────────────────────────────────────────────────
echo "Step 2: Installing Docker CE..."
if command -v docker &>/dev/null; then
  echo "  Docker already installed: $(docker --version)"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
  echo "  Docker installed: $(docker --version)"
fi
echo ""

# ── Step 3: Add user to docker group ─────────────────────────────────────────
echo "Step 3: Adding $USERNAME to docker group..."
if id -nG "$USERNAME" | grep -qw docker; then
  echo "  $USERNAME is already in the docker group."
else
  usermod -aG docker "$USERNAME"
  echo "  Added $USERNAME to docker group."
fi
echo ""

# ── Step 4: AWS CLI (optional) ────────────────────────────────────────────────
if [[ "$WITH_AWSCLI" -eq 1 ]]; then
  echo "Step 4: Installing AWS CLI v2..."
  if command -v aws &>/dev/null; then
    echo "  AWS CLI already installed: $(aws --version)"
  else
    TMPDIR="$(mktemp -d)"
    ARCH_AWS="$(uname -m)"  # x86_64 or aarch64
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH_AWS}.zip" \
      -o "$TMPDIR/awscliv2.zip"
    unzip -q "$TMPDIR/awscliv2.zip" -d "$TMPDIR"
    "$TMPDIR/aws/install"
    rm -rf "$TMPDIR"
    echo "  AWS CLI installed: $(aws --version)"
  fi
  echo ""
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo "================================================================"
echo " Root setup complete."
echo ""
echo " IMPORTANT: Log out and back in (or run: newgrp docker) for the"
echo " docker group membership to take effect for $USERNAME."
echo ""
echo " Then, as $USERNAME, run:"
echo "   ./setup_user.sh"
echo "================================================================"
