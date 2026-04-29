# NONMEM Bug Report: Runtime Crash (SIGSEGV) with ADVAN13 + gfortran 13/14

**Date:** 2026-04-05
**Reporter:** Human Predictions LLC
**NONMEM versions affected:** 7.5.1, 7.6.0
**Severity:** High — reproducible crash; estimation never completes

---

## Summary

NONMEM crashes with a segmentation fault (SIGSEGV) during FOCEI estimation when all
three of the following conditions are met:

1. NONMEM version 7.5.1 or 7.6.0
2. Compiled and run with **gfortran 13 or 14**
3. Model uses **ADVAN13** (user-defined ODE system) with a 3-compartment structure

The crash occurs mid-estimation (typically after 15–25 iterations) and is
**100% reproducible** — every run of the affected control streams on the affected
compiler versions terminates with SIGSEGV.  The same control streams run successfully
on gfortran ≤ 12.

---

## Affected combinations (confirmed by repeated testing)

| NONMEM | gfortran | Ubuntu | Control stream | Result  |
|--------|----------|--------|---------------|---------|
| 7.5.1  | 14       | 24.04  | runODE069     | SIGSEGV |
| 7.5.1  | 14       | 24.04  | runODE070     | SIGSEGV |
| 7.6.0  | 13       | 24.04  | runODE063     | SIGSEGV |
| 7.6.0  | 14       | 24.04  | runODE068     | SIGSEGV |

**Not affected (same control streams, older gfortran):**

| NONMEM | gfortran | Ubuntu | Control stream | Result |
|--------|----------|--------|---------------|--------|
| 7.5.1  | 12       | 24.04  | runODE069     | OK     |
| 7.5.1  | 12       | 24.04  | runODE070     | OK     |
| 7.6.0  | 12       | 24.04  | runODE063     | OK     |
| 7.6.0  | 12       | 24.04  | runODE068     | OK     |
| 7.6.0  | 9        | 24.04  | runODE063     | OK     |

---

## How to reproduce

### Requirements

- NONMEM 7.5.1 or 7.6.0 installed with gfortran 13 or 14
- The control stream and data files in this directory

### Steps

```bash
# Reproduce crash with NONMEM 7.6.0 + gfortran 13 (runODE063 on Oral_2CPT.csv)
cd /path/to/this/directory
mkdir -p repro && cp runODE063.ctl Oral_2CPT.csv repro/
cd repro
/opt/NONMEM/nm_current/util/nmfe runODE063.ctl runODE063.lst > runODE063.nmfe.log 2>&1
# Expected: SIGSEGV crash mid-estimation; nmfe log shows segfault backtrace

# Reproduce crash with NONMEM 7.5.1 + gfortran 14 (runODE070 on Oral_2CPTMM.csv)
cd /path/to/this/directory
mkdir -p repro2 && cp runODE070.ctl Oral_2CPTMM.csv repro2/
cd repro2
/opt/NONMEM/nm_current/util/nmfe runODE070.ctl runODE070.lst > runODE070.nmfe.log 2>&1
# Expected: SIGSEGV crash mid-estimation
```

### Using Docker (if Docker is available)

The crashes were discovered using the `humanpredictions/nonmem` Docker images.
If you have access to these images the exact commands used were:

```bash
# NONMEM 7.6.0 + gfortran 13 + Ubuntu 24.04
docker run --rm \
  --volume "$(pwd):/data" \
  humanpredictions/nonmem:7.6.0-ubuntu24.04-gfortran13-amd64 \
  sh -c 'cd /data && /opt/NONMEM/nm_current/util/nmfe runODE063.ctl runODE063.lst'

# NONMEM 7.5.1 + gfortran 14 + Ubuntu 24.04
docker run --rm \
  --volume "$(pwd):/data" \
  humanpredictions/nonmem:7.5.1-ubuntu24.04-gfortran14-amd64 \
  sh -c 'cd /data && /opt/NONMEM/nm_current/util/nmfe runODE070.ctl runODE070.lst'
```

---

## Model description

All four affected control streams implement **oral 2-compartment PK models** using
`$SUBROUTINE ADVAN13` (user-defined ODE system) with FOCEI (`METHOD=COND INTER`).

| File       | Model                                  | Data file       | Obs   |
|------------|----------------------------------------|-----------------|-------|
| runODE063  | 2-CPT oral, CL/V/Q/V3/KA, all doses   | Oral_2CPT.csv   | 6,960 |
| runODE068  | 2-CPT oral, Michaelis-Menten, SD only  | Oral_2CPTMM.csv | 2,280 |
| runODE069  | 2-CPT oral, Michaelis-Menten, MD only  | Oral_2CPTMM.csv | 2,280 |
| runODE070  | 2-CPT oral, Michaelis-Menten, all doses| Oral_2CPTMM.csv | 2,280 |

The `$DES` block in all models defines a 3-compartment ODE system (absorption,
central, peripheral).  The crash occurs during FOCEI estimation after 15–25
iterations of the quasi-Newton optimization — NMTRAN and compilation succeed
without error.

---

## Crash output

The nmfe log shows:

```
Program received signal SIGSEGV: Segmentation fault - invalid memory reference.

Backtrace for this error:
#0  0x... in ???
#1  0x... in ???
...
/opt/NONMEM/nm_current/util/nmfe: line 468: NNN Segmentation fault (core dumped) ./$nmexec ...
Done with nonmem execution
```

Full crash logs are included in this directory:

- `crash-7.6.0-gfortran13-runODE063.log`
- `crash-7.6.0-gfortran14-runODE068.log`
- `crash-7.5.1-gfortran14-runODE069.log`
- `crash-7.5.1-gfortran14-runODE070.log`

---

## Test system

```
Hardware:    Lenovo ThinkStation P620
CPU:         AMD Ryzen Threadripper PRO 3955WX (16-core, family 23 model 49 stepping 0)
             AVX2 + FMA; microcode 0x830107c
RAM:         32 GB
Host OS:     Ubuntu 24.04.4 LTS (Noble Numbat), kernel 6.17.0-19-generic
Host arch:   x86_64
```

NONMEM was run inside Docker containers based on Ubuntu 24.04 with the specified
gfortran version; the host CPU and kernel are as above.

---

## Additional notes

- **gfortran 12 and earlier**: the same control streams run to completion without
  error on all tested NONMEM 7.5.1 and 7.6.0 images with gfortran ≤ 12.
- **Crash timing**: the crash occurs reproducibly mid-estimation (after several
  optimization iterations complete and gradient output is printed), not during
  compilation or NMTRAN.
- **Other ADVAN13 models**: not all ADVAN13 models crash — lower-dimensional or
  simpler ODE systems appear unaffected.  The crash appears linked to the 3-compartment
  structure with Michaelis-Menten terms or the specific data size (120 subjects).
- **Tested on**: 54 control streams total (36 ODE, 18 analytically solved).  Only
  these 4 ADVAN13 models exhibit the crash; all 18 analytically solved models and
  32 of 36 ODE models run successfully with gfortran 13/14.
