#!/bin/bash
# setup-docker-build.sh — Build humanpredictions/nonmem Docker images from source
#
# Usage:
#   ./setup-docker-build.sh [--jobs N] [--arm64]
#
# This script builds NONMEM Docker images locally using the Pharmacometrics-Docker
# submodule. It requires NONMEM installer zip files and a license from Icon
# (the NONMEM vendor). See README for instructions on obtaining and placing
# these files.
#
# Prerequisites:
#   - ./setup_user.sh has been run (submodules initialized)
#   - Pharmacometrics-Docker/nonmem_passwords.conf exists and is filled in
#     (copy from Pharmacometrics-Docker/nonmem_passwords.conf.example)
#   - NONMEM zip files and nonmem.lic placed in NONMEM_ZIP_DIR
#     (as configured in nonmem_passwords.conf)
#   - Docker installed and running
#   - For arm64 builds on amd64 host: docker buildx + QEMU (see README)
#
# On a Raspberry Pi (arm64), native arm64 builds are performed by default.
# On an amd64 host, use --arm64 to cross-compile arm64 images.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/Pharmacometrics-Docker"
CONF_FILE="$BUILD_DIR/nonmem_passwords.conf"
CONF_EXAMPLE="$BUILD_DIR/nonmem_passwords.conf.example"

# ── Defaults ──────────────────────────────────────────────────────────────────
JOBS="${JOBS:-4}"
ARM64_FLAG=""

# Detect architecture — if we're on arm64, pass --arm64 automatically
if [[ "$(uname -m)" == "aarch64" ]]; then
  ARM64_FLAG="--arm64"
fi

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --jobs N    Parallel builds (default: $JOBS)
  --arm64     Build arm64 images (auto-enabled on arm64 hosts; use on amd64
              to cross-compile via docker buildx + QEMU)
  -h, --help  Show this help
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)  JOBS="$2"; shift 2 ;;
    --arm64) ARM64_FLAG="--arm64"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

echo "================================================================"
echo " NONMEM Docker image build from source"
echo "================================================================"
echo " Build dir:    $BUILD_DIR"
echo " Architecture: $(uname -m)$([ -n "$ARM64_FLAG" ] && echo " (arm64 build enabled)")"
echo " Jobs:         $JOBS"
echo " Date:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "================================================================"
echo ""

# ── Pre-flight checks ─────────────────────────────────────────────────────────
echo "Checking prerequisites..."

# Submodule initialized?
if [[ ! -f "$BUILD_DIR/build_matrix.sh" ]]; then
  echo "ERROR: Pharmacometrics-Docker submodule not initialized."
  echo "  Run: ./setup_user.sh"
  exit 1
fi

# nonmem_passwords.conf exists?
if [[ ! -f "$CONF_FILE" ]]; then
  echo "ERROR: $CONF_FILE not found."
  echo ""
  echo "  Copy the example and fill in your NONMEM passwords and zip file location:"
  echo "    cp $CONF_EXAMPLE $CONF_FILE"
  echo "    \$EDITOR $CONF_FILE"
  echo ""
  echo "  See README for instructions on setting up nonmem_passwords.conf."
  exit 1
fi

# Load config to get NONMEM_ZIP_DIR
# shellcheck source=/dev/null
source "$CONF_FILE"
NONMEM_ZIP_DIR="${NONMEM_ZIP_DIR:-}"

if [[ -z "$NONMEM_ZIP_DIR" ]]; then
  echo "ERROR: NONMEM_ZIP_DIR is not set in $CONF_FILE"
  exit 1
fi

if [[ ! -d "$NONMEM_ZIP_DIR" ]]; then
  echo "ERROR: NONMEM_ZIP_DIR directory does not exist: $NONMEM_ZIP_DIR"
  echo "  Create it and place your NONMEM zip files and nonmem.lic there."
  exit 1
fi

# Check for license file
if [[ ! -f "$NONMEM_ZIP_DIR/nonmem.lic" ]]; then
  echo "ERROR: $NONMEM_ZIP_DIR/nonmem.lic not found."
  echo "  Place your NONMEM license file (nonmem.lic) in $NONMEM_ZIP_DIR"
  exit 1
fi

# Check for at least one NONMEM zip file
if ! ls "$NONMEM_ZIP_DIR"/NONMEM*.zip &>/dev/null; then
  echo "ERROR: No NONMEM*.zip files found in $NONMEM_ZIP_DIR"
  echo "  Place your NONMEM installer zip files there."
  echo "  Expected files (arm64 needs only 7.5.1 and 7.6.0):"
  echo "    NONMEM751.zip  — NONMEM 7.5.1"
  echo "    NONMEM760.zip  — NONMEM 7.6.0"
  exit 1
fi

echo "  Prerequisites OK."
echo ""

# ── Build ─────────────────────────────────────────────────────────────────────
echo "Building images (log: $BUILD_DIR/build_matrix.log)..."
echo "This will take a long time. Monitor progress with:"
echo "  tail -f $BUILD_DIR/build_matrix.log"
echo ""

cd "$BUILD_DIR"
bash build_matrix.sh --jobs "$JOBS" $ARM64_FLAG

echo ""
echo "Build complete. Check $BUILD_DIR/build_matrix.log for results."
echo ""
echo "Run the comparison from the repo root:"
echo "  make -j\$(nproc)"
