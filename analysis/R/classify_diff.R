# classify_diff.R - Classify the magnitude of relative differences across
# NONMEM image variants into discrete tiers, and summarise tier counts.
#
# The reproducibility argument hinges on distinguishing "results that are
# essentially the same" from "results that diverge in a way that would
# change scientific conclusions". Five tiers, with thresholds chosen on
# pharmacometric grounds:
#
#   identical    |Delta/x| <  1e-6   bit-equivalent or within machine epsilon
#   noise        |Delta/x| <  1e-3   below typical NONMEM convergence tolerance
#                                     (SIGDIG=3 in many models); statistically
#                                     indistinguishable from re-running the
#                                     same software
#   small        |Delta/x| <  1e-2   detectable but unlikely to alter PK summary
#                                     statistics like Cl, Vd, half-life when
#                                     reported to 3 significant figures
#   substantial  |Delta/x| <  1e-1   could shift covariate effect interpretation
#                                     or AUC/Cmax estimates by a noticeable
#                                     fraction; deserves investigation
#   major        |Delta/x| >= 1e-1   results disagree by >= 10% - different model
#                                     in any practical sense
#
# These thresholds intentionally span 5 orders of magnitude on a logarithmic
# scale so that the resulting heatmaps and summary tables make it easy to
# see *where* the cliff between numerical noise and meaningful change sits.
#
# Parameters whose `is_fixed` column is TRUE (FIX in the NONMEM control
# stream, signalled by SE = 0 in the cov matrix) are excluded from tier
# classification: they are trivially identical across every run and would
# otherwise inflate the "identical" tier counts.

DIFF_TIERS <- c("identical", "noise", "small", "substantial", "major")

# Numeric thresholds (upper bounds, exclusive) for each tier.
DIFF_THRESHOLDS <- c(
  identical   = 1e-6,
  noise       = 1e-3,
  small       = 1e-2,
  substantial = 1e-1
)

#' Classify a vector of relative differences into the five tiers.
classify_rel_diff <- function(rel_diff) {
  out <- rep(NA_character_, length(rel_diff))
  ar <- abs(rel_diff)
  out[ar <  DIFF_THRESHOLDS["identical"]] <- "identical"
  out[ar >= DIFF_THRESHOLDS["identical"]   & ar <  DIFF_THRESHOLDS["noise"]]       <- "noise"
  out[ar >= DIFF_THRESHOLDS["noise"]       & ar <  DIFF_THRESHOLDS["small"]]       <- "small"
  out[ar >= DIFF_THRESHOLDS["small"]       & ar <  DIFF_THRESHOLDS["substantial"]] <- "substantial"
  out[ar >= DIFF_THRESHOLDS["substantial"]]                                        <- "major"
  factor(out, levels = DIFF_TIERS, ordered = TRUE)
}

# Helper: TRUE/FALSE coercion that maps NA to FALSE.
isTRUE_vec <- function(x) {
  if (is.null(x)) return(rep(FALSE, 0L))
  out <- as.logical(x)
  out[is.na(out)] <- FALSE
  out
}

#' Compute reference-relative differences for a tidy parameter frame.
#'
#' Reference for each (ctl, param_type, param_name) is the median across all
#' converged, non-fixed runs. Median (vs mean) keeps a single outlying tag
#' from skewing the reference; converged-only avoids contaminating with
#' failed estimations; non-fixed avoids the "identical" tier being inflated
#' by FIX parameters that are trivially equal across versions.
#'
#' Fixed-parameter rows are kept in the output (so the user can see what was
#' fixed) but get tier = NA so they are excluded from tier counts and from
#' variance decomposition.
add_reference_diffs <- function(df) {
  key <- paste(df$ctl, df$param_type, df$param_name, sep = "|")

  fixed <- isTRUE_vec(df$is_fixed)

  pickable <- df$converged & is.finite(df$estimate) & !fixed
  ref_pickable <- tapply(df$estimate[pickable], key[pickable], median, na.rm = TRUE)
  ref_all      <- tapply(df$estimate, key, median, na.rm = TRUE)
  ref <- ifelse(key %in% names(ref_pickable),
                ref_pickable[key],
                ref_all[key])

  df$reference <- as.numeric(ref)
  df$rel_diff <- ifelse(abs(df$reference) > 0,
                        (df$estimate - df$reference) / abs(df$reference),
                        NA_real_)
  df$tier <- classify_rel_diff(df$rel_diff)
  # Drop fixed-parameter tiers so the breakdown reflects only estimated quantities.
  df$tier[fixed] <- NA
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
    grp <- interaction(df[, by, drop = FALSE], drop = TRUE, sep = "|")
  }
  tier <- factor(df$tier, levels = DIFF_TIERS)
  tab <- as.data.frame(table(group = grp, tier = tier), stringsAsFactors = FALSE)

  if (length(by) > 0L) {
    parts <- do.call(rbind, strsplit(as.character(tab$group), "|", fixed = TRUE))
    colnames(parts) <- by
    tab <- cbind(as.data.frame(parts, stringsAsFactors = FALSE), tab[, c("tier", "Freq")])
  } else {
    tab <- tab[, c("tier", "Freq")]
  }
  tab$tier <- factor(tab$tier, levels = DIFF_TIERS, ordered = TRUE)

  if (length(by) > 0L) {
    grp_total <- ave(tab$Freq, tab[, by], FUN = sum)
  } else {
    grp_total <- sum(tab$Freq)
  }
  tab$pct <- ifelse(grp_total > 0, 100 * tab$Freq / grp_total, NA_real_)
  colnames(tab)[colnames(tab) == "Freq"] <- "n"
  tab
}

#' Per-CTL reproducibility score: fraction of (tag x param) combinations in
#' the identical or noise tier (i.e., < 1e-3 relative difference). Higher
#' score = more reproducible.
#'
#' @param df data.frame with tier column (from add_reference_diffs).
#' @param by character vector of grouping columns. Default groups by `ctl`.
score_reproducibility <- function(df, by = "ctl") {
  d <- df[!is.na(df$tier), , drop = FALSE]
  if (nrow(d) == 0L) return(data.frame())
  d$is_good <- d$tier %in% c("identical", "noise")
  d$is_major <- d$tier == "major"
  by <- intersect(by, colnames(d))
  if (length(by) == 0L) by <- character(0L)

  if (length(by) == 0L) {
    out <- data.frame(
      n = nrow(d),
      pct_good  = 100 * mean(d$is_good),
      pct_major = 100 * mean(d$is_major),
      stringsAsFactors = FALSE
    )
  } else {
    grp <- interaction(d[, by, drop = FALSE], drop = TRUE, sep = "|")
    tbl <- table(grp)
    grp_levels <- names(tbl)
    n_vec <- as.numeric(tbl)
    pct_good <- as.numeric(tapply(d$is_good,  grp, mean, na.rm = TRUE))
    pct_maj  <- as.numeric(tapply(d$is_major, grp, mean, na.rm = TRUE))
    parts <- do.call(rbind, strsplit(grp_levels, "|", fixed = TRUE))
    colnames(parts) <- by
    out <- cbind(
      as.data.frame(parts, stringsAsFactors = FALSE),
      data.frame(n = n_vec,
                 pct_good = 100 * pct_good,
                 pct_major = 100 * pct_maj,
                 stringsAsFactors = FALSE)
    )
  }
  out[order(out$pct_good), , drop = FALSE]
}
