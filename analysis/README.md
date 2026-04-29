# Cross-version reproducibility analysis

Reads every NONMEM `.lst` result file produced by the `nonmem-compare` runs
(under `<workdir>/<tag>/{ode,solved}/*.lst`) and quantifies how parameter
estimates vary across NONMEM version, Ubuntu LTS version, gfortran version,
and CPU architecture.

The analytical artefacts produced here support a planned scientific journal
publication arguing that pharmacometric reproducibility is best framed in
terms of **result-level reproducibility and context** rather than reverence
for any single "gold-standard" build.

## Prerequisites

R ≥ 4.0 with the following CRAN packages:

```r
install.packages(c(
  "nonmem2rx",
  "dplyr", "tidyr", "ggplot2",
  "optparse", "scales"
))
```

`nonmem2rx` carries the parsing functions (`nmlst()`, `nmtab()`); the rest are
standard tidyverse/utility packages. We deliberately do **not** depend on
`xpose`, `xpose4`, `nonmemica`, or `pmxTools` — every quantity needed is
covered by `nonmem2rx` directly.

## Run

```bash
cd analysis
Rscript analyze_results.R                  # uses default workdir = parent dir
Rscript analyze_results.R --workdir /path  # explicit workdir
Rscript analyze_results.R --max-tags 2     # quick 2-tag verification run
Rscript analyze_results.R --no-cache       # ignore cached parse, re-read .lst files
```

CLI flags:

| Flag                 | Meaning                                                        |
|----------------------|----------------------------------------------------------------|
| `--workdir DIR`      | Root directory containing `<tag>/{ode,solved}/*.lst` trees     |
| `--cores N`          | Parallel parsing workers (default `detectCores() - 1`)         |
| `--cache PATH`       | Path to `.rds` cache of parsed results                         |
| `--no-cache`         | Force re-parse even if cache exists                            |
| `--max-tags N`       | Cap number of tags processed (0 = all). Useful for testing.    |

Expected runtime on the full result set (~10 000 `.lst` files):
- 30–45 minutes on a desktop with 8 cores
- 2–3 hours on a Raspberry Pi 4/5

## Outputs

Everything written to `analysis/outputs/` (gitignored):

```
outputs/
├── parsed_results.rds                       # cache of raw nmlst() output
├── analysis_report.md                       # human-readable summary
├── data/
│   ├── nonmem_compare.csv                   # population-level tidy frame
│   ├── nonmem_compare_individuals.csv       # per-subject ETA realisations
│   ├── pairwise_diffs.csv                   # relative diffs from per-CTL median
│   ├── diff_summary.csv                     # tier counts by parameter class
│   ├── variance_decomp.csv                  # factor variance shares
│   ├── ofv_summary.csv                      # per-CTL OFV statistics (chi-squared scale)
│   ├── ctl_reproducibility.csv              # per-CTL reproducibility score
│   ├── model_class_reproducibility.csv      # per-class reproducibility score
│   └── convergence_matrix.csv               # (ctl × tag) success/fail
└── figures/
    ├── forest_thetas.pdf
    ├── ofv_distribution.pdf                 # ΔOFV with χ² reference lines
    ├── heatmap_diff_classes.pdf
    ├── variance_decomp_summary.pdf
    ├── ctl_reproducibility.pdf              # per-CTL tier breakdown stacked bars
    └── convergence_matrix.pdf
```

### `nonmem_compare.csv` schema

| column            | meaning                                                          |
|-------------------|------------------------------------------------------------------|
| `tag`             | image tag (e.g. `7.6.0-ubuntu24.04-gfortran12-arm64`)            |
| `nm_version`      | parsed NONMEM version (`7.6.0`)                                  |
| `ubuntu_version`  | parsed Ubuntu LTS version (`24.04`)                              |
| `gfortran_version`| parsed gfortran version (`12`, or `4.8` for older Ubuntus)       |
| `arch`            | `amd64` or `arm64`                                               |
| `model_dir`       | `ode` or `solved`                                                |
| `ctl`             | CTL filename without extension (`runODE001`)                     |
| `model_class`     | first token of `$PROB` line (e.g. `Bolus_1CPT_VCL`, `Oral1_2CPT_KAV1QV2VMKM`) |
| `advan`           | NONMEM ADVAN routine from `$SUBR` (e.g. `ADVAN1`, `ADVAN13`)     |
| `trans`           | NONMEM TRANS spec from `$SUBR` (e.g. `TRANS2`); `NA` if not given |
| `is_ode`          | `TRUE` for general ODE solvers (ADVAN6/8/9/13/14/15)             |
| `is_mm`           | `TRUE` if `MM` appears in the `$PROB` model name (Michaelis-Menten) |
| `param_type`      | `theta`/`omega`/`sigma`/`eta_shrinkage`/`epsilon_shrinkage`/`meta` |
| `param_name`      | parameter label (`theta1`, `eta2`, `omega1.2`, `eps1`, `eta_shrinkage_TYPE4_1`, …) |
| `estimate`        | NONMEM scalar estimate (or shrinkage value)                      |
| `se`              | standard error from `sqrt(diag(cov))`; NA where covariance step failed |
| `is_fixed`        | `TRUE` if the parameter was `FIX` in the control stream (signalled by SE=0 in cov); `FALSE` for estimated; `NA` for shrinkage rows where the concept doesn't apply |
| `converged`       | `TRUE` if the .lst contained `"Stop Time:"`                      |
| `ofv`             | objective function value for the run                             |
| `n_obs`           | NONMEM-reported number of observations                           |
| `n_sub`           | NONMEM-reported number of subjects                               |
| `elapsed_sec`     | total elapsed estimation time                                    |
| `term_info`       | NONMEM termination message (first non-empty line)                |

Fixed parameters (`is_fixed = TRUE`) are kept in `nonmem_compare.csv` so you
can see what was fixed, but they are **excluded** from `pairwise_diffs.csv`
tier classification, from `variance_decomp.csv`, and from per-CTL/per-class
reproducibility scores. They would otherwise inflate the "identical" tier
since they are trivially identical across all runs.

### `nonmem_compare_individuals.csv` schema

| column           | meaning                                                                   |
|------------------|---------------------------------------------------------------------------|
| `tag` … `arch`   | same metadata columns as above                                            |
| `model_dir`,`ctl`| as above                                                                  |
| `subject_id`     | NONMEM subject ID                                                         |
| `quantity`       | `eta1`, `eta2`, … (per-subject empirical Bayes ETA realisations)          |
| `index`          | numeric ETA index (1, 2, …)                                               |
| `value`          | scalar value from `.phi`                                                  |

### Reproducibility-tier classification

`pairwise_diffs.csv` and the heatmap PDF use a five-tier classification of
the relative difference `(estimate − median_for_ctl_param) / |median|`:

| tier         | range            | interpretation                                         |
|--------------|------------------|--------------------------------------------------------|
| identical    | `< 1e-6`         | bit-equivalent / within machine epsilon                |
| noise        | `[1e-6, 1e-3)`   | below typical NONMEM convergence tolerance             |
| small        | `[1e-3, 1e-2)`   | detectable; unlikely to alter PK summary statistics    |
| substantial  | `[1e-2, 1e-1)`   | could shift covariate effects or AUC/Cmax noticeably   |
| major        | `≥ 1e-1`         | results disagree by ≥ 10% — different model in practice |

The reference value for each `(ctl, param_name)` is the median across all
*converged, non-fixed* runs for that combination. Fixed parameters (FIX in
the control stream) get `tier = NA` and are excluded from tier counts.

### OFV variability — chi-squared scale

OFV is `-2 log-likelihood`, so absolute differences map onto a chi-squared
distribution with 1 degree of freedom (matching a typical nested
likelihood-ratio test). `ofv_summary.csv` reports for each CTL:

| column            | meaning                                                          |
|-------------------|------------------------------------------------------------------|
| `range_ofv`       | `max(OFV) - min(OFV)` across converged tags                      |
| `max_abs_dev`     | max `|OFV - median|` across converged tags                       |
| `pct_within_385`  | `%` of tags whose OFV is within 3.84 of the per-CTL median (p=0.05 LRT) |
| `pct_within_663`  | `%` within 6.63 (p=0.01 LRT)                                     |
| `pct_within_1083` | `%` within 10.83 (p=0.001 LRT)                                   |

For *the same model on the same data* across image variants any systematic
ΔOFV is purely numerical, but these thresholds tell us whether the
disagreement is large enough to alter a typical nested-model comparison.

### Reproducibility ranking

`ctl_reproducibility.csv` and `model_class_reproducibility.csv` rank CTLs
and model classes by `pct_good`, the fraction of `(tag × parameter)` cells
in identical or noise tier (i.e. relative diff < 1e-3). Higher = more
reproducible. `pct_major` is the fraction in the worst tier (≥ 10%
relative diff). Useful for spotting which model classes (e.g. analytic
ADVAN1-4 vs general ODE solver ADVAN13) are systematically more or less
reproducible across image variants.

### Variance decomposition

`variance_decomp.csv` reports the share of total across-tag variance for each
`(ctl, param_name)` attributable to each factor, computed via Type II sums of
squares with `lm(estimate ~ nm_version + ubuntu_version + gfortran_version +
arch)`. Factors with only a single level for a given parameter contribute 0
share automatically. Caveat: gfortran versions are nested in Ubuntu releases,
so the shares are not perfectly orthogonal — they are descriptive, not
inferential.

## Re-running selectively

The script caches parsed `nmlst()` output in `outputs/parsed_results.rds`. On
a re-run with the same workdir it loads the cache and skips re-parsing
(typically dropping a 30-minute job to ~10 seconds). The cache is invalidated
automatically when the set of `.lst` files changes (new tags or new CTLs).
Use `--no-cache` to force a fresh parse.
