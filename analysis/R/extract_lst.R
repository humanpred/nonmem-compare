# extract_lst.R — Extract a tidy long-format data frame of population-level
# parameter estimates, standard errors, OFV, convergence status, and shrinkage
# values from a single NONMEM .lst file (plus its companion .shk and .phi
# files when present).
#
# All extraction is performed via the `nonmem2rx` package — `nmlst()` for the
# .lst, `nmtab()` for .shk and .phi. No manual text-parsing of those files.
#
# nonmem2rx labels parameters as:
#   "theta1", "theta2", ...           — fixed effects
#   "eta1", "eta2", ...               — diagonal OMEGA elements
#                                       (between-subject variances)
#   "omega1.2", "omega1.3", ...       — off-diagonal OMEGA covariances
#   "eps1", "eps2", ...               — diagonal SIGMA elements
#
# Standard errors are obtained from sqrt(diag(cov)); the cov matrix is named
# with the same labels.

suppressPackageStartupMessages({
  library(nonmem2rx)
})

# ---------------------------------------------------------------------------
# Convergence: NONMEM writes "Stop Time:" near the very end of a complete .lst
# file. We use the same heuristic the Makefile uses to gate .lstinterim → .lst
# rename. Any file not matching that pattern is treated as "not converged"
# (could be incomplete, crashed, or partial). We separately capture termInfo
# from nmlst() which gives more diagnostic detail.
is_converged <- function(lst_path) {
  if (!file.exists(lst_path)) return(FALSE)
  con <- file(lst_path, "r")
  on.exit(close(con))
  # Read the last few lines without slurping the whole file.
  # NONMEM "Stop Time:" appears within the final ~5 lines.
  lines <- tryCatch({
    n <- 6L
    tail_lines <- character(0)
    while (length(l <- readLines(con, n = 1L, warn = FALSE)) > 0L) {
      tail_lines <- c(tail_lines, l)
      if (length(tail_lines) > n) tail_lines <- tail_lines[-1]
    }
    tail_lines
  }, error = function(e) character(0))
  any(grepl("Stop Time:", lines, fixed = TRUE))
}

# ---------------------------------------------------------------------------
# Get a named numeric vector of standard errors from the cov matrix.
# Returns a length-zero numeric if cov is missing or invalid.
get_ses <- function(cov_mat) {
  if (is.null(cov_mat) || !is.matrix(cov_mat)) return(numeric(0))
  d <- diag(cov_mat)
  # Negative diagonals (numerical issues) → NA SE rather than NaN
  d[!is.finite(d) | d < 0] <- NA_real_
  out <- sqrt(d)
  names(out) <- rownames(cov_mat)
  out
}

# ---------------------------------------------------------------------------
# Resolve a cov-matrix label (e.g. "theta1", "eta2", "omega1.2", "eps1") to
# the corresponding scalar estimate using the parsed nmlst() result.
estimate_for_label <- function(label, res) {
  # theta{N}
  m <- regmatches(label, regexec("^theta(\\d+)$", label))[[1]]
  if (length(m) == 2L) {
    i <- as.integer(m[2])
    if (i <= length(res$theta)) return(unname(res$theta[i]))
    return(NA_real_)
  }
  # eta{N} → diagonal OMEGA
  m <- regmatches(label, regexec("^eta(\\d+)$", label))[[1]]
  if (length(m) == 2L) {
    i <- as.integer(m[2])
    if (!is.null(res$omega) && i <= nrow(res$omega)) return(res$omega[i, i])
    return(NA_real_)
  }
  # omega{i}.{j} → off-diagonal OMEGA covariance
  m <- regmatches(label, regexec("^omega(\\d+)\\.(\\d+)$", label))[[1]]
  if (length(m) == 3L) {
    i <- as.integer(m[2]); j <- as.integer(m[3])
    if (!is.null(res$omega) && max(i, j) <= nrow(res$omega)) {
      return(res$omega[max(i, j), min(i, j)])  # lower triangle
    }
    return(NA_real_)
  }
  # eps{N} → diagonal SIGMA
  m <- regmatches(label, regexec("^eps(\\d+)$", label))[[1]]
  if (length(m) == 2L) {
    i <- as.integer(m[2])
    if (!is.null(res$sigma) && i <= nrow(res$sigma)) return(res$sigma[i, i])
    return(NA_real_)
  }
  NA_real_
}

# Map cov-matrix label to a (param_type, param_name) pair for the tidy frame.
# theta1     → (theta, theta1)
# eta2       → (omega, eta2)             (diagonal OMEGA element)
# omega1.2   → (omega, omega1.2)         (off-diagonal)
# eps1       → (sigma, eps1)
classify_label <- function(label) {
  if (grepl("^theta\\d+$",  label)) return(c("theta",  label))
  if (grepl("^eta\\d+$",    label)) return(c("omega",  label))
  if (grepl("^omega\\d+\\.\\d+$", label)) return(c("omega", label))
  if (grepl("^eps\\d+$",    label)) return(c("sigma",  label))
  c("other", label)
}

# ---------------------------------------------------------------------------
# Main extractor. Returns a data.frame with columns:
#   tag, model_dir, ctl, param_type, param_name, estimate, se, converged,
#   ofv, n_obs, n_sub, elapsed_sec, term_info
# Plus shrinkage rows if a .shk file is present.
#
# `tag`, `model_dir`, `ctl` are pulled from the path; metadata columns
# (nm_version, etc.) are joined later by the main pipeline.
extract_lst <- function(lst_path) {
  # Path components.
  ctl       <- sub("\\.lst$", "", basename(lst_path))
  model_dir <- basename(dirname(lst_path))                 # "ode" or "solved"
  tag       <- basename(dirname(dirname(lst_path)))        # the image tag

  base_cols <- function(...) {
    data.frame(
      tag = tag, model_dir = model_dir, ctl = ctl,
      ..., stringsAsFactors = FALSE
    )
  }

  # Convergence is computed regardless of whether nmlst() succeeds.
  converged <- is_converged(lst_path)

  res <- tryCatch(nmlst(lst_path), error = function(e) {
    structure(list(error = conditionMessage(e)), class = "nmlst_error")
  })
  if (inherits(res, "nmlst_error")) {
    return(base_cols(
      param_type = "meta", param_name = "parse_error",
      estimate = NA_real_, se = NA_real_,
      converged = converged, ofv = NA_real_,
      n_obs = NA_integer_, n_sub = NA_integer_,
      elapsed_sec = NA_real_, term_info = res$error
    ))
  }

  ofv         <- if (!is.null(res$objf)) as.numeric(res$objf) else NA_real_
  n_obs       <- if (!is.null(res$nobs)) as.integer(res$nobs) else NA_integer_
  n_sub       <- if (!is.null(res$nsub)) as.integer(res$nsub) else NA_integer_
  elapsed_sec <- if (!is.null(res$time)) as.numeric(res$time) else NA_real_
  term_info   <- if (!is.null(res$termInfo)) {
    # Trim to first non-empty content line for compactness.
    ti <- res$termInfo
    if (is.character(ti) && length(ti) > 0L) {
      l <- trimws(strsplit(ti, "\n", fixed = TRUE)[[1]])
      l <- l[nzchar(l)]
      if (length(l) > 0) l[1] else NA_character_
    } else NA_character_
  } else NA_character_

  # ---- Population-level parameters & SEs ----
  ses <- get_ses(res$cov)
  param_rows <- list()

  if (length(ses) > 0L) {
    for (lbl in names(ses)) {
      cls <- classify_label(lbl)
      param_rows[[length(param_rows) + 1L]] <- base_cols(
        param_type  = cls[1],
        param_name  = cls[2],
        estimate    = estimate_for_label(lbl, res),
        se          = unname(ses[lbl]),
        converged   = converged,
        ofv         = ofv,
        n_obs       = n_obs,
        n_sub       = n_sub,
        elapsed_sec = elapsed_sec,
        term_info   = term_info
      )
    }
  } else {
    # Fallback: cov matrix unavailable. Still emit estimates (no SE).
    if (!is.null(res$theta) && length(res$theta) > 0L) {
      for (i in seq_along(res$theta)) {
        nm <- names(res$theta)[i] %||% sprintf("theta%d", i)
        param_rows[[length(param_rows) + 1L]] <- base_cols(
          param_type  = "theta", param_name = nm,
          estimate    = unname(res$theta[i]), se = NA_real_,
          converged   = converged, ofv = ofv,
          n_obs = n_obs, n_sub = n_sub,
          elapsed_sec = elapsed_sec, term_info = term_info
        )
      }
    }
    if (!is.null(res$omega)) {
      for (i in seq_len(nrow(res$omega))) for (j in seq_len(i)) {
        v <- res$omega[i, j]
        if (i == j) {
          nm <- sprintf("eta%d", i)
        } else {
          nm <- sprintf("omega%d.%d", i, j)
          if (v == 0) next  # skip zero off-diagonals (they were not estimated)
        }
        param_rows[[length(param_rows) + 1L]] <- base_cols(
          param_type  = "omega", param_name = nm,
          estimate    = v, se = NA_real_,
          converged   = converged, ofv = ofv,
          n_obs = n_obs, n_sub = n_sub,
          elapsed_sec = elapsed_sec, term_info = term_info
        )
      }
    }
    if (!is.null(res$sigma)) {
      for (i in seq_len(nrow(res$sigma))) {
        param_rows[[length(param_rows) + 1L]] <- base_cols(
          param_type  = "sigma", param_name = sprintf("eps%d", i),
          estimate    = res$sigma[i, i], se = NA_real_,
          converged   = converged, ofv = ofv,
          n_obs = n_obs, n_sub = n_sub,
          elapsed_sec = elapsed_sec, term_info = term_info
        )
      }
    }
  }

  # ---- Shrinkage from .shk via nmtab() ----
  shk_path <- sub("\\.lst$", ".shk", lst_path)
  if (file.exists(shk_path)) {
    shk <- tryCatch(nmtab(shk_path), error = function(e) NULL)
    if (!is.null(shk) && nrow(shk) > 0L) {
      # All columns of the form ETA(i) hold per-ETA shrinkage statistics;
      # TYPE indexes which statistic (per NONMEM 7.5+ docs: TYPE=1 ETAbar,
      # TYPE=2 SE_ETAbar, TYPE=3 P-value, TYPE=4 ETAshrinkSD%, etc.). We
      # keep all TYPE rows so downstream analyses can pick the relevant one.
      eta_cols <- grep("^ETA\\(", colnames(shk), value = TRUE)
      ets_cols <- grep("^ETS\\(", colnames(shk), value = TRUE)  # mixture etas (rare)
      eps_cols <- grep("^EPS\\(", colnames(shk), value = TRUE)  # EPS shrinkage if present
      for (col in c(eta_cols, ets_cols, eps_cols)) {
        # ETA index parsed from the column name.
        idx <- as.integer(gsub("^[A-Z]+\\((\\d+)\\)$", "\\1", col))
        prefix <- if (col %in% eps_cols) "epsilon_shrinkage" else "eta_shrinkage"
        for (r in seq_len(nrow(shk))) {
          type_code <- shk$TYPE[r]
          name <- sprintf("%s_TYPE%d_%d", prefix, type_code, idx)
          param_rows[[length(param_rows) + 1L]] <- base_cols(
            param_type  = if (col %in% eps_cols) "epsilon_shrinkage" else "eta_shrinkage",
            param_name  = name,
            estimate    = shk[[col]][r],
            se          = NA_real_,
            converged   = converged, ofv = ofv,
            n_obs       = n_obs, n_sub = n_sub,
            elapsed_sec = elapsed_sec, term_info = term_info
          )
        }
      }
    }
  }

  if (length(param_rows) == 0L) {
    return(base_cols(
      param_type = "meta", param_name = "no_params",
      estimate = NA_real_, se = NA_real_,
      converged = converged, ofv = ofv,
      n_obs = n_obs, n_sub = n_sub,
      elapsed_sec = elapsed_sec, term_info = term_info
    ))
  }

  do.call(rbind, param_rows)
}

# ---------------------------------------------------------------------------
# Individuals: per-subject ETA realizations from .phi via nmtab().
# Columns are ID, ETA(1), ETA(2), ..., ETC(...) (covariance entries), OBJ, NMREP.
# We emit a long format with one row per (subject, ETA index).
extract_individuals <- function(lst_path) {
  ctl       <- sub("\\.lst$", "", basename(lst_path))
  model_dir <- basename(dirname(lst_path))
  tag       <- basename(dirname(dirname(lst_path)))

  phi_path <- sub("\\.lst$", ".phi", lst_path)
  if (!file.exists(phi_path)) return(NULL)

  phi <- tryCatch(nmtab(phi_path), error = function(e) NULL)
  if (is.null(phi) || nrow(phi) == 0L) return(NULL)

  eta_cols <- grep("^ETA\\(", colnames(phi), value = TRUE)
  if (length(eta_cols) == 0L) return(NULL)

  id_col <- if ("ID" %in% colnames(phi)) "ID" else "SUBJECT_NO"

  # Build long format.
  pieces <- lapply(eta_cols, function(col) {
    idx <- as.integer(gsub("^ETA\\((\\d+)\\)$", "\\1", col))
    data.frame(
      tag         = tag,
      model_dir   = model_dir,
      ctl         = ctl,
      subject_id  = phi[[id_col]],
      quantity    = sprintf("eta%d", idx),
      index       = idx,
      value       = phi[[col]],
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, pieces)
}

# Convenience: %||% for "use right-hand-side if left is NULL".
`%||%` <- function(a, b) if (is.null(a)) b else a
