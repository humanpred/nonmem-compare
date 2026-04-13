#!/bin/bash
# collect-results.sh — Package NONMEM comparison results into a zip archive
#
# Usage:
#   ./collect-results.sh [--output FILE]
#
# Creates a timestamped zip file containing all NONMEM output files from the
# make run, plus system_details.txt. Build artifacts and temporary run
# directories are excluded.
#
# Output files included per run:
#   .lst .ext .cov .cor .coi .phi .xml .grd .shk .shm .clt .cpu .nmfe.log
# Directory-level files included:
#   .failures  system_details.txt
#
# Default output filename: nonmem-results-YYYYMMDD-HHMMSS.zip

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT="${OUTPUT:-$SCRIPT_DIR/nonmem-results-${TIMESTAMP}.zip}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --output FILE   Output zip file path (default: nonmem-results-TIMESTAMP.zip)
  -h, --help      Show this help
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

cd "$SCRIPT_DIR"

echo "================================================================"
echo " NONMEM compare — collect results"
echo "================================================================"
echo " Output: $OUTPUT"
echo " Date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "================================================================"
echo ""

# ── Count what we have ───────────────────────────────────────────────────────
COMPLETE=$(find . -mindepth 3 -maxdepth 3 -name "*.lst" \
  -not -path "./.git/*" \
  -not -path "./nlmixr2test/*" \
  -not -path "./Pharmacometrics-Docker/*" | \
  while read -r f; do
    tail -2 "$f" 2>/dev/null | head -1 | grep -qF "Stop Time:" && echo ok
  done | wc -l)

INCOMPLETE=$(find . -mindepth 3 -maxdepth 3 -name "*.lst" \
  -not -path "./.git/*" \
  -not -path "./nlmixr2test/*" \
  -not -path "./Pharmacometrics-Docker/*" | \
  while read -r f; do
    tail -2 "$f" 2>/dev/null | head -1 | grep -qF "Stop Time:" || echo bad
  done | wc -l)

echo "Results found:"
echo "  Complete .lst files:   $COMPLETE"
echo "  Incomplete .lst files: $INCOMPLETE"
echo ""

if [[ "$COMPLETE" -eq 0 ]]; then
  echo "WARNING: No complete .lst files found. Has make been run?"
  echo "  Run: make -j\$(nproc)"
  exit 1
fi

if [[ "$INCOMPLETE" -gt 0 ]]; then
  echo "WARNING: $INCOMPLETE incomplete .lst files will be excluded from the zip."
  echo "  Re-run 'make -j\$(nproc)' to retry incomplete runs before collecting."
  echo ""
fi

# ── Build the zip ────────────────────────────────────────────────────────────
echo "Building zip..."

# Collect paths to include:
#   - system_details.txt (top-level)
#   - tag/ode/*.lst, *.ext, *.cov, *.cor, *.coi, *.phi, *.xml,
#                   *.grd, *.shk, *.shm, *.clt, *.cpu, *.nmfe.log, .failures
#   - tag/solved/* same extensions
#
# Exclude: -run/ subdirectories and any build artifacts

# Build a temporary file list
TMPLIST="$(mktemp)"
trap 'rm -f "$TMPLIST"' EXIT

# system_details.txt
[[ -f system_details.txt ]] && echo "system_details.txt" >> "$TMPLIST"

# Per-tag result files — find tag dirs (NAME-ubuntu*-gfortran*-{amd64,arm64})
find . -maxdepth 1 -type d \
  -name '*-ubuntu*-gfortran*-amd64' \
  -o -name '*-ubuntu*-gfortran*-arm64' 2>/dev/null | sort | \
while read -r tagdir; do
  tagdir="${tagdir#./}"
  for subdir in ode solved; do
    dir="$tagdir/$subdir"
    [[ -d "$dir" ]] || continue
    # Output files
    for ext in lst ext cov cor coi phi xml grd shk shm clt cpu nmfe.log; do
      find "$dir" -maxdepth 1 -name "*.${ext}" ! -path "*-run/*" 2>/dev/null
    done
    # .failures
    [[ -f "$dir/.failures" ]] && echo "$dir/.failures"
  done
done >> "$TMPLIST"

NFILES=$(wc -l < "$TMPLIST")
echo "  Including $NFILES files..."

zip -q "$OUTPUT" --names-stdin < "$TMPLIST"

SIZE=$(du -sh "$OUTPUT" | cut -f1)
echo "  Done: $OUTPUT ($SIZE)"
echo ""
echo "Share this file for cross-version comparison analysis."
