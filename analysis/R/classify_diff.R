# classify_diff.R — Classify the magnitude of relative differences across
# NONMEM image variants into discrete tiers, and summarise tier counts.
#
# The reproducibility argument hinges on distinguishing "results that are
# essentially the same" from "results that diverge in a way that would
# change scientific conclusions". Five tiers, with thresholds chosen on
# pharmacometric grounds:
#
#   identical    |Δ/x| <  1e-6   bit-equivalent or within machine epsilon
#   noise        |Δ/x| <  1e-3   below typical NONMEM convergence tolerance
#                                 (SIGDIG=3 in many models); statistically
#                                 indistinguishable from re-running the
#                                 same software
#   small        |Δ/x| <  1e-2   detectable but unlikely to alter PK summary
#                                 statistics like Cl, Vd, half-life when
#                                 reported to 3 significant figures
#   substantial  |Δ/x| <  1e-1   could shift covariate effect interpretation
#                                 or AUC/Cmax estimates by a noticeable
#                                 fraction; deserves investigation
#   major        |Δ/x| >= 1e-1   results disagree by ≥ 10% — different model
#                                 in any practical sense
#
# These thresholds intentionally span 5 orders of magnitude on a logarithmic
# scale so that the resulting heatmaps and summary tables make it easy to
# see *where* the cliff between numerical noise and meaningful change sits.

DIFF_TIERS <- c("identical", "noise", "small", "substantial", "major")

# Numeric thresholds (upper bounds, exclusive) for each tier.
# A relative diff with abs() less than the threshold falls into the
# corresponding tier; "major" is the catch-all for >= 0.1.
DIFF_THRESHOLDS <- c(
  identical   = 1e-6,
  noise       = 1e-3,
  small       = 1e-2,
  substantial = 1e-1
)

#' Classify a vector of relative differences into the five tiers.
#'
#' @param rel_diff numeric vector of relative differences (estimate / reference - 1).
#'   NA inputs propagate to NA tiers.
#' @return ordered factor with levels DIFF_TIERS.
classify_rel_diff <- function(rel_diff) {
  out <- rep(NA_character_, length(rel_diff))
  ar <- abs(rel_diff)
  out[ar <  DIFF_THRESHOLDS["identical"]]                                   <- "identical"
  out[ar >= DIFF_THRESHOLDS["identical"]   & ar <  DIFF_THRESHOLDS["noise"]]       <- "noise"
  out[ar >= DIFF_THRESHOLDS["noise"]       & ar <  DIFF_THRESHOLDS["small"]]       <- "small"
  out[ar >= DIFF_THRESHOLDS["small"]       & ar <  DIFF_THRESHOLDS["substantial"]] <- "substantial"
  out[ar >= DIFF_THRESHOLDS["substantial"]]                                  <- "major"
  factor(out, levels = DIFF_TIERS, ordered = TRUE)
}

#' Compute reference-relative differences for a tidy parameter frame.
#'
#' Reference for each (ctl, param_type, param_name) is the *median across all
#' converged runs*. Choosing the median rather than mean keeps a single
#' outlying tag from skewing the reference; choosing converged runs avoids
#' contaminating the reference with failed estimations.
#'
#' @param df data.frame with columns tag, ctl, param_type, param_name, estimate,
#'   converged. Must come from rbind() of multiple extract_lst() outputs.
#' @return df augmented with `reference`, `rel_diff`, `tier` columns.
add_reference_diffs <- function(df) {
  # Group key.
  key <- paste(df$ctl, df$param_type, df$param_name, sep = "")

  # Reference = median across converged runs only. Falls back to median across
  # all runs if no converged runs exist for a given key (rare).
  conv_only <- df$converged & is.finite(df$estimate)
  ref_converged <- tapply(df$estimate[conv_only], key[conv_only], median, na.rm = TRUE)
  ref_all       <- tapply(df$estimate, key, median, na.rm = TRUE)
  ref <- ifelse(key %in% names(ref_converged),
                ref_converged[key],
                ref_all[key])

  df$reference <- as.numeric(ref)
  # Use abs(reference) in denominator; if reference is exactly 0 the relative
  # difference is undefined → NA.
  df$rel_diff <- ifelse(abs(df$reference) > 0,
                        (df$estimate - df$reference) / abs(df$reference),
                        NA_real_)
  df$tier <- classify_rel_diff(df$rel_diff)
  df
}

#' Tabulate tier counts.
#'
#' @param df data.frame with `tier` column (output of add_reference_diffs).
#' @param by character vector of grouping columns. Counts and percentages are
#'   computed within each group.
#' @return long-format data.frame with one row per (group, tier).
summarize_diffs <- function(df, by = "param_type") {
  by <- intersect(by, colnames(df))
  if (length(by) == 0L) {
    grp <- factor(rep("all", nrow(df)))
  } else {
    grp <- interaction(df[, by, drop = FALSE], drop = TRUE, sep = "")
  }
  tier <- factor(df$tier, levels = DIFF_TIERS)
  tab <- as.data.frame(table(group = grp, tier = tier), stringsAsFactors = FALSE)

  # Split group key back into the original by-columns.
  if (length(by) > 0L) {
    parts <- do.call(rbind, strsplit(as.character(tab$group), "", fixed = TRUE))
    colnames(parts) <- by
    tab <- cbind(as.data.frame(parts, stringsAsFactors = FALSE), tab[, c("tier", "Freq")])
  } else {
    tab <- tab[, c("tier", "Freq")]
  }
  tab$tier <- factor(tab$tier, levels = DIFF_TIERS, ordered = TRUE)

  # Percentages per group.
  if (length(by) > 0L) {
    grp_total <- ave(tab$Freq, tab[, by], FUN = sum)
  } else {
    grp_total <- sum(tab$Freq)
  }
  tab$pct <- ifelse(grp_total > 0, 100 * tab$Freq / grp_total, NA_real_)
  colnames(tab)[colnames(tab) == "Freq"] <- "n"
  tab
}
