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
              "model_dir", "ctl", "param_type", "param_name", "estimate", "se",
              "converged", "ofv", "n_obs", "n_sub", "elapsed_sec", "term_info")
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

# ---------------------------------------------------------------------------
# Stage 7: OFV summary per CTL.
one_per <- unique(pop_pop[, c("tag", "ctl", "ofv", "converged", "nm_version",
                              "arch")])
ofv_conv <- one_per[one_per$converged & is.finite(one_per$ofv), ]
ofv_summary <- ofv_conv %>%
  group_by(ctl) %>%
  summarise(
    n_tags     = n(),
    median_ofv = median(ofv),
    min_ofv    = min(ofv),
    max_ofv    = max(ofv),
    range_ofv  = max(ofv) - min(ofv),
    rel_range  = (max(ofv) - min(ofv)) / abs(median(ofv)),
    .groups    = "drop"
  ) %>%
  arrange(desc(rel_range))
write.csv(ofv_summary, file.path(data_dir, "ofv_summary.csv"), row.names = FALSE)
cat(sprintf("Wrote %s (%d CTLs)\n",
            file.path(data_dir, "ofv_summary.csv"), nrow(ofv_summary)))

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
         width = 12, height = 10)
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

add("## Variance decomposition — top 10 most-variable parameters")
add("Per-parameter share of variance attributable to each factor (Type II SS,")
add("converged runs only). Higher share = factor explains more of the spread.\n")
add("| ctl | param | n | NM | Ubuntu | gfortran | arch | residual |")
add("|-----|-------|--:|---:|-------:|---------:|-----:|---------:|")
top_decomp <- decomp[order(-decomp$var_total), ]
for (i in seq_len(min(10, nrow(top_decomp)))) {
  r <- top_decomp[i, ]
  fmt <- function(x) if (is.na(x)) "—" else sprintf("%.1f%%", 100 * x)
  add("| %s | %s | %d | %s | %s | %s | %s | %s |",
      r$ctl, r$param_name, r$n_obs,
      fmt(r$share_nm_version), fmt(r$share_ubuntu_version),
      fmt(r$share_gfortran_version), fmt(r$share_arch),
      fmt(r$share_residual))
}
add("")

add("## OFV variability — top 10 CTLs with widest range")
add("| ctl | n_tags | median OFV | range | range/|median| |")
add("|-----|------:|----------:|------:|--------------:|")
for (i in seq_len(min(10, nrow(ofv_summary)))) {
  r <- ofv_summary[i, ]
  add("| %s | %d | %.4g | %.4g | %.2e |",
      r$ctl, r$n_tags, r$median_ofv, r$range_ofv, r$rel_range)
}
add("")

add("## Output files")
add("- `outputs/data/nonmem_compare.csv` — population-level tidy data")
add("- `outputs/data/nonmem_compare_individuals.csv` — per-subject ETAs")
add("- `outputs/data/pairwise_diffs.csv` — relative diffs from per-CTL median")
add("- `outputs/data/diff_summary.csv` — tier counts per parameter class")
add("- `outputs/data/variance_decomp.csv` — variance share by factor")
add("- `outputs/data/ofv_summary.csv` — per-CTL OFV statistics")
add("- `outputs/data/convergence_matrix.csv` — (ctl × tag) status")
add("- `outputs/figures/*.pdf` — visualisations")
add("- `outputs/parsed_results.rds` — cache of raw nmlst() output")

writeLines(md, file.path(out_dir, "analysis_report.md"))
cat(sprintf("Wrote %s\n", file.path(out_dir, "analysis_report.md")))

cat("\nDone.\n")
