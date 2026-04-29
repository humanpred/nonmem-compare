#!/bin/bash
# reproduce.sh — verify NONMEM ADVAN13 + gfortran 13/14 crash
# Usage: ./reproduce.sh [/path/to/nmfe]
# If nmfe path is not given, assumes /opt/NONMEM/nm_current/util/nmfe
set -euo pipefail

NMFE="${1:-/opt/NONMEM/nm_current/util/nmfe}"
DIR="$(cd "$(dirname "$0")" && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_test() {
  local ctl="$1" csv="$2" desc="$3"
  local workdir="$TMPDIR_BASE/$ctl"
  mkdir -p "$workdir"
  cp "$DIR/$ctl.ctl" "$DIR/$csv" "$workdir/"
  echo "--- Testing $ctl ($desc) ---"
  if "$NMFE" "$workdir/$ctl.ctl" "$workdir/$ctl.lst" > "$workdir/$ctl.nmfe.log" 2>&1; then
    if grep -qF "Stop Time:" "$workdir/$ctl.lst" 2>/dev/null; then
      echo "  PASS: Completed successfully"
    else
      echo "  FAIL: nmfe exited 0 but no 'Stop Time:' in output"
    fi
  else
    local exit_code=$?
    if grep -qF "Segmentation fault" "$workdir/$ctl.nmfe.log" 2>/dev/null; then
      echo "  CRASH (SIGSEGV confirmed): exit code $exit_code — BUG REPRODUCED"
    else
      echo "  FAIL: exit code $exit_code (see $workdir/$ctl.nmfe.log)"
    fi
  fi
  echo "  Log: $workdir/$ctl.nmfe.log"
}

echo "NONMEM ADVAN13 + gfortran 13/14 crash reproduction"
echo "nmfe: $NMFE"
echo ""

run_test runODE063 Oral_2CPT.csv   "NONMEM 7.6.0 + gfortran 13, 2-CPT oral all doses"
run_test runODE068 Oral_2CPTMM.csv "NONMEM 7.6.0 + gfortran 14, 2-CPT MM single dose"
run_test runODE069 Oral_2CPTMM.csv "NONMEM 7.5.1 + gfortran 14, 2-CPT MM multiple dose"
run_test runODE070 Oral_2CPTMM.csv "NONMEM 7.5.1 + gfortran 14, 2-CPT MM all doses"

echo ""
echo "Done."
