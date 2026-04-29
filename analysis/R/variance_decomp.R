# variance_decomp.R — Decompose the across-tag variance of each
# (ctl, param_name) into the share attributable to NONMEM version, Ubuntu
# LTS version, gfortran version, and CPU architecture.
#
# Method: ordinary least squares with all four factors entered as additive
# fixed effects. Type II sums of squares give the variance share controlling
# for the other factors (vs. Type I, which depends on entry order). When a
# factor has only a single level in the available data its column collapses
# and contributes 0 SS — handled gracefully by the helper.
#
# This is intentionally a coarse, descriptive decomposition: with nested
# factors (e.g. gfortran versions are tied to Ubuntu releases) the shares
# are not perfectly orthogonal, but the *relative* magnitudes still tell us
# which factor dominates the spread for each parameter. A formal mixed-model
# analysis is out of scope for this script — Type II SS shares are the
# right level of detail for a screening-level reproducibility report.

#' Decompose variance of `estimate` across the supplied grouping columns.
#'
#' @param df data.frame with columns ctl, param_type, param_name, estimate,
#'   nm_version, ubuntu_version, gfortran_version, arch, converged.
#' @return data.frame with one row per (ctl, param_type, param_name) and
#'   columns giving the share (proportion 0..1) of total SS attributable to
#'   each factor plus residual share.
decompose_variance <- function(df) {
  # Drop failed runs (would otherwise inflate residual SS) and fixed-value
  # rows (zero variance by construction; not informative about reproducibility).
  fixed <- isTRUE_vec(df$is_fixed)
  df <- df[df$converged & is.finite(df$estimate) & !fixed, , drop = FALSE]

  # Factor levels prepared as character (lm coerces to factor anyway, but this
  # keeps type predictable).
  for (col in c("nm_version", "ubuntu_version", "gfortran_version", "arch")) {
    df[[col]] <- as.character(df[[col]])
  }

  # Collapse-safe Type II SS calc: drop a factor from the model if it only has
  # one level (e.g. arch=arm64 only).
  factors_all <- c("nm_version", "ubuntu_version", "gfortran_version", "arch")

  group_keys <- unique(df[, c("ctl", "param_type", "param_name")])

  rows <- vector("list", nrow(group_keys))
  for (k in seq_len(nrow(group_keys))) {
    sub <- df[df$ctl              == group_keys$ctl[k] &
              df$param_type       == group_keys$param_type[k] &
              df$param_name       == group_keys$param_name[k], , drop = FALSE]

    n <- nrow(sub)
    var_total <- if (n >= 2L) var(sub$estimate) else 0
    if (!is.finite(var_total) || var_total == 0) {
      # All values identical (or only one observation) → no variance to explain.
      rows[[k]] <- data.frame(
        group_keys[k, , drop = FALSE],
        n_obs = n,
        var_total = var_total,
        share_nm_version       = NA_real_,
        share_ubuntu_version   = NA_real_,
        share_gfortran_version = NA_real_,
        share_arch             = NA_real_,
        share_residual         = NA_real_,
        stringsAsFactors = FALSE
      )
      next
    }

    active <- factors_all[vapply(factors_all, function(f) {
      length(unique(sub[[f]])) > 1L
    }, logical(1L))]

    if (length(active) == 0L) {
      # All factors collapsed but variance > 0 → entirely residual.
      rows[[k]] <- data.frame(
        group_keys[k, , drop = FALSE],
        n_obs = n,
        var_total = var_total,
        share_nm_version       = 0,
        share_ubuntu_version   = 0,
        share_gfortran_version = 0,
        share_arch             = 0,
        share_residual         = 1,
        stringsAsFactors = FALSE
      )
      next
    }

    # Total SS (about the mean).
    ss_total <- var_total * (n - 1L)

    # Type II SS = SS(full) - SS(full - factor) for each factor; equivalently
    # the reduction in residual SS when adding that factor last to the model
    # containing all the others.
    full_formula <- as.formula(paste("estimate ~", paste(active, collapse = " + ")))
    full_fit <- tryCatch(lm(full_formula, data = sub), error = function(e) NULL)
    if (is.null(full_fit)) {
      rows[[k]] <- data.frame(
        group_keys[k, , drop = FALSE],
        n_obs = n,
        var_total = var_total,
        share_nm_version       = NA_real_,
        share_ubuntu_version   = NA_real_,
        share_gfortran_version = NA_real_,
        share_arch             = NA_real_,
        share_residual         = NA_real_,
        stringsAsFactors = FALSE
      )
      next
    }
    rss_full <- sum(residuals(full_fit)^2)

    shares <- setNames(rep(0, length(factors_all)), factors_all)
    for (f in active) {
      reduced_terms <- setdiff(active, f)
      if (length(reduced_terms) == 0L) {
        reduced_formula <- as.formula("estimate ~ 1")
      } else {
        reduced_formula <- as.formula(paste("estimate ~", paste(reduced_terms, collapse = " + ")))
      }
      reduced_fit <- tryCatch(lm(reduced_formula, data = sub), error = function(e) NULL)
      if (is.null(reduced_fit)) next
      ss_factor <- sum(residuals(reduced_fit)^2) - rss_full
      shares[f] <- max(0, ss_factor) / ss_total
    }
    share_residual <- max(0, rss_full / ss_total)

    rows[[k]] <- data.frame(
      group_keys[k, , drop = FALSE],
      n_obs = n,
      var_total = var_total,
      share_nm_version       = shares["nm_version"],
      share_ubuntu_version   = shares["ubuntu_version"],
      share_gfortran_version = shares["gfortran_version"],
      share_arch             = shares["arch"],
      share_residual         = share_residual,
      stringsAsFactors = FALSE
    )
  }

  do.call(rbind, rows)
}
