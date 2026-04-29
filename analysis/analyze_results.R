#!/usr/bin/env Rscript
#
# analyze_results.R — Main entry point for the NONMEM cross-version
# reproducibility analysis. Walks every <tag>/{ode,solved}/*.lst file under
# the working directory, extracts parameter estimates / SEs / OFV / shrinkage
# via the `nonmem2rx` package, and produces:
#
#   outputs/data/nonmem_compare.csv             — population-level tidy frame
#   outputs/data/nonmem_compare_individuals.csv — per-subject ETA realisations
#   outputs/data/pairwise_diffs.csv             — reference-relative differences
#   outputs/data/diff_summary.csv               — tier counts per param_type
#   outputs/data/variance_decomp.csv            — factor variance shares
#   outputs/data/ofv_summary.csv                — per-CTL OFV statistics
#   outputs/data/convergence_matrix.csv         — (ctl × tag) status
#   outputs/figures/forest_thetas.pdf
#   outputs/figures/ofv_distribution.pdf
#   outputs/figures/heatmap_diff_classes.pdf
#   outputs/figures/variance_decomp_summary.pdf
#   outputs/figures/convergence_matrix.pdf
#   outputs/analysis_report.md
#   outputs/parsed_results.rds                  — cache of raw nmlst() output
#
# Usage:
#   Rscript analyze_results.R [--workdir DIR] [--cores N] [--cache PATH]
#                              [--no-cache] [--max-tags N]
#
# --workdir   Root directory containing <tag>/{ode,solved}/<ctl>.lst trees.
#             Defaults to the parent directory of this script.
# --cores     Parallel workers for parsing. Defaults to detectCores()-1.
# --cache     Path to .rds cache of parsed_results. Defaults to
#             outputs/parsed_results.rds.
# --no-cache  Force re-parse, ignoring any existing cache.
# --max-tags  Cap on number of tags processed (useful for verification on a
#             subset). 0 = unlimited.

suppressPackageStartupMessages({
  library(optparse)
  library(parallel)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
})

# ---------------------------------------------------------------------------
# Parse CLI args.
opt_parser <- OptionParser(option_list = list(
  make_option(c("-w", "--workdir"),  type = "character", default = NULL,
              help = "Root directory containing <tag>/{ode,solved}/*.lst trees"),
  make_option(c("-j", "--cores"),    type = "integer",   default = NULL,
              help = "Parallel workers [default: detectCores()-1]"),
  make_option(c("-c", "--cache"),    type = "character", default = NULL,
              help = "Path to .rds cache of parsed_results"),
  make_option("--no-cache",          action = "store_true", default = FALSE,
              help = "Ignore any existing cache and re-parse"),
  make_option("--max-tags",          type = "integer",   default = 0L,
              help = "Cap on number of tags (0 = all)")
))
opt <- parse_args(opt_parser)

# ---------------------------------------------------------------------------
# Resolve paths.
script_path <- (function() {
  args <- commandArgs(trailingOnly = FALSE)
  hit <- grep("^--file=", args)
  if (length(hit)) {
    normalizePath(sub("^--file=", "", args[hit[1]]))
  } else {
    "analyze_results.R"
  }
})()
script_dir   <- dirname(script_path)
analysis_dir <- script_dir

source(file.path(analysis_dir, "R", "parse_tag.R"))
source(file.path(analysis_dir, "R", "extract_lst.R"))
source(file.path(analysis_dir, "R", "classify_diff.R"))
source(file.path(analysis_dir, "R", "variance_decomp.R"))
source(file.path(analysis_dir, "R", "plots.R"))

workdir <- if (!is.null(opt$workdir)) {
  normalizePath(opt$workdir)
} else {
  normalizePath(file.path(analysis_dir, ".."))
}
cores   <- opt$cores %||% max(1L, parallel::detectCores() - 1L)
out_dir <- file.path(analysis_dir, "outputs")
data_dir <- file.path(out_dir, "data")
fig_dir  <- file.path(out_dir, "figures")
dir.create(data_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(fig_dir,  showWarnings = FALSE, recursive = TRUE)
cache_path <- opt$cache %||% file.path(out_dir, "parsed_results.rds")

cat(sprintf("workdir: %s\ncores:   %d\ncache:   %s\n\n",
            workdir, cores, cache_path))

# ---------------------------------------------------------------------------
# Stage 1: discover .lst files.
tag_dirs <- list.dirs(workdir, recursive = FALSE, full.names = TRUE)
tag_pattern <- "^.+-ubuntu\\d+\\.\\d+-gfortran\\d+(\\.\\d+)?-(amd64|arm64|arm)$"
tag_dirs <- tag_dirs[grepl(tag_pattern, basename(tag_dirs))]

if (opt$`max-tags` > 0L) tag_dirs <- head(tag_dirs, opt$`max-tags`)

lst_files <- character()
for (td in tag_dirs) {
  for (sub in c("ode", "solved")) {
    p <- file.path(td, sub)
    if (dir.exists(p)) {
      lst_files <- c(lst_files, list.files(p, pattern = "\\.lst$",
                                           full.names = TRUE))
    }
  }
}
cat(sprintf("Discovered %d tags, %d .lst files\n",
            length(tag_dirs), length(lst_files)))

# ---------------------------------------------------------------------------
# Stage 2: parse via mclapply, with cache.
parsed <- NULL
if (!opt$`no-cache` && file.exists(cache_path)) {
  cat(sprintf("Loading cache from %s ...\n", cache_path))
  parsed <- readRDS(cache_path)
  # Invalidate cache if file set differs.
  if (!setequal(parsed$lst_files, lst_files)) {
    cat("  cache mismatch (lst file set differs) — re-parsing\n")
    parsed <- NULL
  }
}

if (is.null(parsed)) {
  cat(sprintf("Parsing %d files with %d cores ...\n", length(lst_files), cores))
  t0 <- Sys.time()

  parse_one <- function(f) {
    pop <- tryCatch(extract_lst(f), error = function(e) {
      data.frame(
        tag       = basename(dirname(dirname(f))),
        model_dir = basename(dirname(f)),
        ctl       = sub("\\.lst$", "", basename(f)),
        param_type = "meta", param_name = "extract_error",
        estimate = NA_real_, se = NA_real_,
        converged = FALSE, ofv = NA_real_,
        n_obs = NA_integer_, n_sub = NA_integer_,
        elapsed_sec = NA_real_,
        term_info = conditionMessage(e),
        stringsAsFactors = FALSE
      )
    })
    ind <- tryCatch(extract_individuals(f), error = function(e) NULL)
    list(pop = pop, ind = ind)
  }

  res_list <- mclapply(lst_files, parse_one, mc.cores = cores)
  pop_df <- do.call(rbind, lapply(res_list, `[[`, "pop"))
  ind_df <- do.call(rbind, Filter(Negate(is.null),
                                  lapply(res_list, `[[`, "ind")))

  parsed <- list(lst_files = lst_files, pop = pop_df, ind = ind_df)
  saveRDS(parsed, cache_path)
  cat(sprintf("  parsed in %.1f s; cached to %s\n",
              as.numeric(difftime(Sys.time(), t0, units = "secs")),
              cache_path))
} else {
  cat(sprintf("  loaded %d population rows, %d individual rows from cache\n",
              nrow(parsed$pop), nrow(parsed$ind %||% data.frame())))
}

pop <- parsed$pop
ind <- parsed$ind

# ---------------------------------------------------------------------------
# Stage 3: join tag metadata.
tag_meta <- parse_tag(unique(pop$tag))
pop <- merge(pop, tag_meta, by = "tag", all.x = TRUE)
if (!is.null(ind) && nrow(ind) > 0L) {
  ind <- merge(ind, tag_meta, by = "tag", all.x = TRUE)
}

# Re-order columns for readability.
pop_cols <- c("tag", "nm_version", "ubuntu_version", "gfortran_version", "arch",
              "model_dir", "ctl", "model_class", "advan", "trans", "is_ode",
              "is_mm", "param_type", "param_name", "estimate", "se",
              "is_fixed", "converged", "ofv", "n_obs", "n_sub",
              "elapsed_sec", "term_info")
pop <- pop[, intersect(pop_cols, colnames(pop)), drop = FALSE]

cat(sprintf("Joined metadata: %d tags, %d population rows\n",
            length(unique(pop$tag)), nrow(pop)))

# ---------------------------------------------------------------------------
# Stage 4: write tidy CSVs.
write.csv(pop, file.path(data_dir, "nonmem_compare.csv"), row.names = FALSE)
cat(sprintf("Wrote %s (%d rows)\n",
            file.path(data_dir, "nonmem_compare.csv"), nrow(pop)))

if (!is.null(ind) && nrow(ind) > 0L) {
  ind_cols <- c("tag", "nm_version", "ubuntu_version", "gfortran_version",
                "arch", "model_dir", "ctl", "subject_id", "quantity", "index",
                "value")
  ind <- ind[, intersect(ind_cols, colnames(ind)), drop = FALSE]
  write.csv(ind, file.path(data_dir, "nonmem_compare_individuals.csv"),
            row.names = FALSE)
  cat(sprintf("Wrote %s (%d rows)\n",
              file.path(data_dir, "nonmem_compare_individuals.csv"), nrow(ind)))
}

# ---------------------------------------------------------------------------
# Stage 5: reference-relative differences and tier classification.
# Restrict to population-level scalar parameters; meta rows are dropped.
pop_pop <- pop[pop$param_type %in% c("theta", "omega", "sigma",
                                     "eta_shrinkage", "epsilon_shrinkage"), ,
               drop = FALSE]
pop_pop <- add_reference_diffs(pop_pop)
write.csv(pop_pop[, c("tag", "nm_version", "ubuntu_version",
                      "gfortran_version", "arch", "model_dir", "ctl",
                      "param_type", "param_name", "estimate", "reference",
                      "rel_diff", "tier")],
          file.path(data_dir, "pairwise_diffs.csv"),
          row.names = FALSE)
cat(sprintf("Wrote %s\n", file.path(data_dir, "pairwise_diffs.csv")))

diff_summary <- summarize_diffs(pop_pop, by = c("param_type"))
write.csv(diff_summary, file.path(data_dir, "diff_summary.csv"),
          row.names = FALSE)
cat(sprintf("Wrote %s\n", file.path(data_dir, "diff_summary.csv")))

# ---------------------------------------------------------------------------
# Stage 6: variance decomposition.
decomp <- decompose_variance(pop_pop)
write.csv(decomp, file.path(data_dir, "variance_decomp.csv"),
          row.names = FALSE)
cat(sprintf("Wrote %s (%d parameter rows)\n",
            file.path(data_dir, "variance_decomp.csv"), nrow(decomp)))

# Per-param-type aggregate: median/mean factor shares across all parameters
# of each type. Lets us answer "how much does NM version explain for theta
# parameters as a class" without being dominated by any single CTL.
decomp_by_type <- aggregate_variance_by_type(decomp)
write.csv(decomp_by_type, file.path(data_dir, "variance_decomp_by_type.csv"),
          row.names = FALSE)
cat(sprintf("Wrote %s (%d param types)\n",
            file.path(data_dir, "variance_decomp_by_type.csv"),
            nrow(decomp_by_type)))

# ---------------------------------------------------------------------------
# Stage 7: OFV summary per CTL.
#
# OFV is -2 log-likelihood, so absolute differences map onto a chi-squared(1)
# scale: 3.84 corresponds to p=0.05 in a likelihood-ratio test, 6.63 to p=0.01,
# 10.83 to p=0.001. For *the same model on the same data* across image
# variants, ANY systematic delta is purely numerical, but these reference
# points give a meaningful pharmacometric ruler: delta < 3.84 means no two
# tags would disagree about a nested model comparison at the 5% level.
one_per <- unique(pop_pop[, c("tag", "ctl", "model_class", "advan", "is_ode",
                              "ofv", "converged", "nm_version", "arch")])
ofv_conv <- one_per[one_per$converged & is.finite(one_per$ofv), ]

CHI2_DF1 <- c(p_05 = 3.84, p_01 = 6.63, p_001 = 10.83)

ofv_summary <- ofv_conv %>%
  group_by(ctl, model_class, advan, is_ode) %>%
  summarise(
    n_tags         = n(),
    median_ofv     = median(ofv),
    min_ofv        = min(ofv),
    max_ofv        = max(ofv),
    range_ofv      = max(ofv) - min(ofv),
    max_abs_dev    = max(abs(ofv - median(ofv))),
    pct_within_385 = 100 * mean(abs(ofv - median(ofv)) < CHI2_DF1["p_05"]),
    pct_within_663 = 100 * mean(abs(ofv - median(ofv)) < CHI2_DF1["p_01"]),
    pct_within_1083 = 100 * mean(abs(ofv - median(ofv)) < CHI2_DF1["p_001"]),
    .groups        = "drop"
  ) %>%
  arrange(desc(range_ofv))
write.csv(ofv_summary, file.path(data_dir, "ofv_summary.csv"), row.names = FALSE)
cat(sprintf("Wrote %s (%d CTLs)\n",
            file.path(data_dir, "ofv_summary.csv"), nrow(ofv_summary)))

# ---------------------------------------------------------------------------
# Stage 7b: per-CTL reproducibility score and per-model-class roll-up.
# `pct_good` = fraction of (tag x parameter) combinations that fall in the
# identical or noise tier (i.e. < 1e-3 relative diff). Higher is better.
ctl_meta <- unique(pop_pop[, c("ctl", "model_dir", "model_class", "advan",
                               "trans", "is_ode", "is_mm")])
ctl_score <- score_reproducibility(pop_pop, by = "ctl")
ctl_score <- merge(ctl_score, ctl_meta, by = "ctl", all.x = TRUE)
write.csv(ctl_score[order(ctl_score$pct_good), ],
          file.path(data_dir, "ctl_reproducibility.csv"), row.names = FALSE)
cat(sprintf("Wrote %s\n", file.path(data_dir, "ctl_reproducibility.csv")))

class_score <- score_reproducibility(pop_pop, by = c("model_class", "is_ode"))
write.csv(class_score, file.path(data_dir, "model_class_reproducibility.csv"),
          row.names = FALSE)
cat(sprintf("Wrote %s\n",
            file.path(data_dir, "model_class_reproducibility.csv")))

# ---------------------------------------------------------------------------
# Stage 8: convergence matrix.
conv_mat <- unique(pop[, c("tag", "ctl", "converged")])
conv_wide <- pivot_wider(conv_mat, names_from = "tag", values_from = "converged",
                         values_fn = any, values_fill = NA)
write.csv(conv_wide, file.path(data_dir, "convergence_matrix.csv"),
          row.names = FALSE)
cat(sprintf("Wrote %s\n", file.path(data_dir, "convergence_matrix.csv")))

# ---------------------------------------------------------------------------
# Stage 9: figures.
save_pdf <- function(p, name, width = 10, height = 7) {
  path <- file.path(fig_dir, name)
  ggsave(path, p, width = width, height = height, device = "pdf")
  cat(sprintf("Wrote %s\n", path))
}

save_pdf(plot_forest(pop_pop[pop_pop$param_type == "theta", ],
                     title = "Theta estimates across image variants"),
         "forest_thetas.pdf", width = 14, height = 12)
save_pdf(plot_ofv_distribution(pop), "ofv_distribution.pdf",
         width = 14, height = 7)
save_pdf(plot_tier_heatmap(pop_pop), "heatmap_diff_classes.pdf",
         width = 16, height = 10)
save_pdf(plot_variance_decomp(decomp), "variance_decomp_summary.pdf",
         width = 12, height = 14)
save_pdf(plot_variance_by_type(decomp_by_type),
         "variance_decomp_by_type.pdf",
         width = 9, height = 5)
save_pdf(plot_ctl_reproducibility(pop_pop), "ctl_reproducibility.pdf",
         width = 12, height = 12)
save_pdf(plot_convergence(pop), "convergence_matrix.pdf",
         width = 16, height = 10)

# ---------------------------------------------------------------------------
# Stage 10: markdown summary report.
md <- c()
add <- function(...) md <<- c(md, sprintf(...))
add("# NONMEM cross-version reproducibility — analysis summary\n")
add("Generated: %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"))
add("Workdir: `%s`\n", workdir)

add("## Coverage")
add("- Tags analysed: **%d**", length(unique(pop$tag)))
n_amd64 <- length(unique(pop$tag[pop$arch == "amd64"]))
n_arm64 <- length(unique(pop$tag[pop$arch == "arm64"]))
add("  - amd64: %d", n_amd64)
add("  - arm64: %d", n_arm64)
add("- CTL files: **%d** (%d ODE, %d solved)",
    length(unique(pop$ctl)),
    length(unique(pop$ctl[pop$model_dir == "ode"])),
    length(unique(pop$ctl[pop$model_dir == "solved"])))
add("- Total .lst files parsed: **%d**", length(lst_files))
add("")

add("## Convergence")
total_runs <- nrow(unique(pop[, c("tag", "ctl")]))
converged_runs <- nrow(unique(pop[pop$converged, c("tag", "ctl")]))
add("- Converged: **%d / %d** (%.1f%%)",
    converged_runs, total_runs, 100 * converged_runs / total_runs)
failures <- one_per[!one_per$converged, ]
if (nrow(failures) > 0L) {
  add("- Failures by CTL (top 10):")
  fail_tab <- sort(table(failures$ctl), decreasing = TRUE)
  for (n in names(head(fail_tab, 10))) {
    add("  - `%s`: %d", n, fail_tab[[n]])
  }
}
add("")

add("## Reproducibility tier breakdown")
add("Counts of (tag × ctl × parameter) combinations falling into each tier,")
add("by parameter class.\n")
add("| param_type | identical | noise | small | substantial | major | total |")
add("|------------|----------:|------:|------:|------------:|------:|------:|")
for (pt in unique(diff_summary$param_type)) {
  sub <- diff_summary[diff_summary$param_type == pt, ]
  get_n <- function(t) {
    v <- sub$n[sub$tier == t]
    if (length(v)) v else 0L
  }
  total <- sum(sub$n)
  add("| %s | %d | %d | %d | %d | %d | %d |",
      pt,
      get_n("identical"), get_n("noise"), get_n("small"),
      get_n("substantial"), get_n("major"),
      total)
}
add("")

add("## Variance decomposition by parameter type")
add("Type II SS shares averaged across all parameters of a given type. Each")
add("factor's column shows median (Q25 / Q75) of its share across parameters")
add("of that type that have non-zero across-tag variance.\n")
add("| param_type | n params | NM version | Ubuntu | gfortran | arch | residual |")
add("|------------|--------:|------------|--------|----------|------|----------|")
fmt_iqr <- function(med, q25, q75) {
  if (is.na(med)) return("—")
  sprintf("%.1f%% (%.1f / %.1f)", 100 * med, 100 * q25, 100 * q75)
}
for (i in seq_len(nrow(decomp_by_type))) {
  r <- decomp_by_type[i, ]
  add("| %s | %d | %s | %s | %s | %s | %s |",
      r$param_type, r$n_params,
      fmt_iqr(r$share_nm_version_median,       r$share_nm_version_q25,       r$share_nm_version_q75),
      fmt_iqr(r$share_ubuntu_version_median,   r$share_ubuntu_version_q25,   r$share_ubuntu_version_q75),
      fmt_iqr(r$share_gfortran_version_median, r$share_gfortran_version_q25, r$share_gfortran_version_q75),
      fmt_iqr(r$share_arch_median,             r$share_arch_q25,             r$share_arch_q75),
      fmt_iqr(r$share_residual_median,         r$share_residual_q25,         r$share_residual_q75))
}
add("")

add("### Top 10 most-variable parameters per type")
add("Per-parameter Type II SS shares for the most-variable individual")
add("parameters (highest across-tag variance) within each parameter type.")
add("Useful for spotting *which* parameters are pulling each type's average.\n")
fmt_pct <- function(x) if (is.na(x)) "—" else sprintf("%.1f%%", 100 * x)
for (pt in c("theta", "omega", "eta_shrinkage", "epsilon_shrinkage")) {
  sub <- decomp[decomp$param_type == pt, , drop = FALSE]
  if (nrow(sub) == 0L) next
  sub <- sub[order(-sub$var_total), ]
  add("#### %s", pt)
  add("| ctl | param | n | NM | Ubuntu | gfortran | arch | residual |")
  add("|-----|-------|--:|---:|-------:|---------:|-----:|---------:|")
  for (i in seq_len(min(10, nrow(sub)))) {
    r <- sub[i, ]
    add("| %s | %s | %d | %s | %s | %s | %s | %s |",
        r$ctl, r$param_name, r$n_obs,
        fmt_pct(r$share_nm_version), fmt_pct(r$share_ubuntu_version),
        fmt_pct(r$share_gfortran_version), fmt_pct(r$share_arch),
        fmt_pct(r$share_residual))
  }
  add("")
}

add("## OFV variability across image variants")
add("OFV is -2 log-likelihood, so absolute deltas map to a chi-squared(df=1)")
add("ruler: delta < 3.84 is non-significant at p=0.05 in a likelihood-ratio")
add("test, < 6.63 at p=0.01, < 10.83 at p=0.001. Any systematic delta for")
add("the same model on the same data is purely numerical, but these")
add("thresholds tell us whether the disagreement would change a typical")
add("nested-model comparison.\n")
add("Aggregate across all (ctl x converged tag) pairs:")
all_dev <- abs(ofv_conv$ofv - ave(ofv_conv$ofv, ofv_conv$ctl, FUN = function(x) median(x, na.rm = TRUE)))
add("- N comparisons: %d", length(all_dev))
add("- Pairs with |delta OFV| < 3.84:  %d (%.2f%%)",
    sum(all_dev < CHI2_DF1["p_05"]),  100 * mean(all_dev < CHI2_DF1["p_05"]))
add("- Pairs with |delta OFV| < 6.63:  %d (%.2f%%)",
    sum(all_dev < CHI2_DF1["p_01"]),  100 * mean(all_dev < CHI2_DF1["p_01"]))
add("- Pairs with |delta OFV| < 10.83: %d (%.2f%%)",
    sum(all_dev < CHI2_DF1["p_001"]), 100 * mean(all_dev < CHI2_DF1["p_001"]))
add("- Maximum |delta OFV| observed: %.4g", max(all_dev))
add("")
add("### Top 10 CTLs by OFV range")
add("| ctl | model class | n_tags | median OFV | range OFV | max |dev| | %% within 3.84 |")
add("|-----|-------------|------:|----------:|---------:|---------:|--------------:|")
for (i in seq_len(min(10, nrow(ofv_summary)))) {
  r <- ofv_summary[i, ]
  add("| %s | %s | %d | %.4g | %.4g | %.4g | %.1f%% |",
      r$ctl, r$model_class %||% "?", r$n_tags,
      r$median_ofv, r$range_ofv, r$max_abs_dev, r$pct_within_385)
}
add("")

add("## Reproducibility ranking by CTL — least reproducible first")
add("`pct_good` = fraction of (tag x parameter) cells in identical or noise")
add("tier (i.e., relative diff < 1e-3). Fixed parameters are excluded.\n")
add("| ctl | model class | advan | n params | %% good | %% major |")
add("|-----|-------------|-------|--------:|-------:|--------:|")
for (i in seq_len(min(15, nrow(ctl_score)))) {
  r <- ctl_score[i, ]
  add("| %s | %s | %s | %d | %.1f%% | %.1f%% |",
      r$ctl, r$model_class %||% "?", r$advan %||% "?",
      r$n, r$pct_good, r$pct_major)
}
add("")

add("## Reproducibility by model class")
add("| model class | is_ode | n params | %% good | %% major |")
add("|-------------|:------:|--------:|-------:|--------:|")
for (i in seq_len(nrow(class_score))) {
  r <- class_score[i, ]
  add("| %s | %s | %d | %.1f%% | %.1f%% |",
      r$model_class %||% "?", r$is_ode %||% "?",
      r$n, r$pct_good, r$pct_major)
}
add("")

add("## Output files")
add("- `outputs/data/nonmem_compare.csv` - population-level tidy data")
add("- `outputs/data/nonmem_compare_individuals.csv` - per-subject ETAs")
add("- `outputs/data/pairwise_diffs.csv` - relative diffs from per-CTL median")
add("- `outputs/data/diff_summary.csv` - tier counts per parameter class")
add("- `outputs/data/variance_decomp.csv` - variance share by factor")
add("- `outputs/data/ofv_summary.csv` - per-CTL OFV statistics in chi-squared units")
add("- `outputs/data/ctl_reproducibility.csv` - per-CTL reproducibility score")
add("- `outputs/data/model_class_reproducibility.csv` - per-class reproducibility score")
add("- `outputs/data/convergence_matrix.csv` - (ctl x tag) status")
add("- `outputs/figures/*.pdf` - visualisations")
add("- `outputs/parsed_results.rds` - cache of raw nmlst() output")

writeLines(md, file.path(out_dir, "analysis_report.md"))
cat(sprintf("Wrote %s\n", file.path(out_dir, "analysis_report.md")))

cat("\nDone.\n")
