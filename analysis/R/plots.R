# plots.R — ggplot2 helper functions for the cross-version reproducibility
# analysis. Each function takes a data frame and returns a ggplot object.
# The main driver script (analyze_results.R) saves them to PDF with ggsave().
#
# Plotting style choices: paper-ready figures should be readable in greyscale
# but use colour for fast on-screen scanning. We avoid the default rainbow
# palette and use the viridis colour scale (perceptually uniform, colour-blind
# friendly, prints well in greyscale).

suppressPackageStartupMessages({
  library(ggplot2)
})

# Tier colour palette: divergent, going from "fine" (blue/green) through
# "warning" (yellow) to "alarm" (red). Aligned with DIFF_TIERS order.
TIER_PALETTE <- c(
  identical   = "#2C7BB6",  # blue
  noise       = "#ABD9E9",  # light blue
  small       = "#FFFFBF",  # pale yellow
  substantial = "#FDAE61",  # orange
  major       = "#D7191C"   # red
)

# ---------------------------------------------------------------------------
# Forest-style plot: one panel per CTL × parameter, points = tag-level
# estimates with error bars = ±SE, coloured by NONMEM major version.
# Caller should subset df to one param_type (e.g. theta) and a manageable
# number of CTLs to keep the figure readable.
plot_forest <- function(df, title = NULL) {
  df <- df[df$param_type %in% c("theta", "omega", "sigma") &
           is.finite(df$estimate), , drop = FALSE]
  if (nrow(df) == 0L) {
    return(ggplot() + labs(title = title %||% "(no data)"))
  }
  df$tag <- factor(df$tag, levels = rev(sort(unique(df$tag))))

  p <- ggplot(df, aes(x = estimate, y = tag, colour = nm_version)) +
    geom_point(size = 1.2) +
    facet_wrap(~ ctl + param_name, scales = "free_x") +
    scale_colour_viridis_d(option = "plasma", end = 0.9) +
    labs(
      x = "Parameter estimate",
      y = NULL,
      colour = "NONMEM\nversion",
      title = title
    ) +
    theme_minimal(base_size = 8) +
    theme(
      strip.text = element_text(size = 7),
      axis.text.y = element_text(size = 6),
      legend.position = "right"
    )

  # Error bars only when SE is available and finite.
  if (any(is.finite(df$se) & df$se > 0)) {
    p <- p + geom_errorbarh(
      aes(xmin = estimate - se, xmax = estimate + se),
      height = 0, alpha = 0.6
    )
  }
  p
}

# ---------------------------------------------------------------------------
# OFV per CTL across tags: box-and-strip plot. The OFV is the single best
# scalar reproducibility check, because two estimations that find the same
# minimum should agree to many decimal places.
plot_ofv_distribution <- function(df) {
  # One row per (tag, ctl): take the OFV from the first parameter row of each.
  ofv_df <- unique(df[, c("tag", "ctl", "ofv", "converged",
                          "nm_version", "arch")])
  ofv_df <- ofv_df[ofv_df$converged & is.finite(ofv_df$ofv), , drop = FALSE]
  if (nrow(ofv_df) == 0L) return(ggplot() + labs(title = "(no converged OFV data)"))

  # Centre each CTL's OFV on its median for visual comparability.
  med <- ave(ofv_df$ofv, ofv_df$ctl, FUN = function(x) median(x, na.rm = TRUE))
  ofv_df$ofv_delta <- ofv_df$ofv - med

  ggplot(ofv_df, aes(x = ctl, y = ofv_delta)) +
    geom_jitter(aes(colour = nm_version, shape = arch),
                width = 0.2, height = 0, size = 1.2, alpha = 0.7) +
    geom_boxplot(outlier.shape = NA, fill = NA) +
    scale_colour_viridis_d(option = "plasma", end = 0.9) +
    labs(
      x = NULL,
      y = "OFV - median(OFV) per CTL",
      title = "OFV variability across image variants",
      colour = "NONMEM\nversion",
      shape = "Arch"
    ) +
    theme_minimal(base_size = 9) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 6))
}

# ---------------------------------------------------------------------------
# Tier heatmap: rows = ctl, columns = tag, fill = worst tier observed across
# parameters within that (ctl, tag). Gives a single-glance view of *where*
# reproducibility breaks down.
plot_tier_heatmap <- function(df) {
  pop <- df[df$param_type %in% c("theta", "omega", "sigma") & !is.na(df$tier), , drop = FALSE]
  if (nrow(pop) == 0L) return(ggplot() + labs(title = "(no tiered data)"))

  # Worst tier per (ctl, tag).
  pop$tier_int <- as.integer(pop$tier)
  worst_int <- tapply(pop$tier_int, list(pop$ctl, pop$tag), max, na.rm = TRUE)
  cell <- as.data.frame(as.table(worst_int), stringsAsFactors = FALSE)
  colnames(cell) <- c("ctl", "tag", "tier_int")
  cell$tier <- factor(DIFF_TIERS[cell$tier_int], levels = DIFF_TIERS)
  cell <- cell[!is.na(cell$tier), , drop = FALSE]

  ggplot(cell, aes(x = tag, y = ctl, fill = tier)) +
    geom_tile() +
    scale_fill_manual(values = TIER_PALETTE, drop = FALSE) +
    labs(
      x = "Image tag",
      y = "CTL file",
      fill = "Worst diff tier",
      title = "Cross-version reproducibility heatmap (worst-case parameter)"
    ) +
    theme_minimal(base_size = 8) +
    theme(
      axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5, size = 4),
      axis.text.y = element_text(size = 5)
    )
}

# ---------------------------------------------------------------------------
# Variance decomposition stacked bars. Rows = (ctl, param_name), bar width = 1,
# each bar segmented by share attributable to each factor. Sorted by total
# variance descending so the most-variable parameters appear on top.
plot_variance_decomp <- function(decomp_df, top_n = 50L) {
  d <- decomp_df[is.finite(decomp_df$var_total) & decomp_df$var_total > 0, , drop = FALSE]
  if (nrow(d) == 0L) return(ggplot() + labs(title = "(no decomposable variance)"))

  d$param_label <- paste(d$ctl, d$param_name, sep = " — ")
  d <- d[order(-d$var_total), , drop = FALSE]
  if (nrow(d) > top_n) d <- d[seq_len(top_n), , drop = FALSE]

  long <- data.frame(
    param_label = rep(d$param_label, 5),
    factor = rep(c("NONMEM version", "Ubuntu version", "gfortran version", "Architecture", "Residual"),
                 each = nrow(d)),
    share = c(d$share_nm_version, d$share_ubuntu_version,
              d$share_gfortran_version, d$share_arch, d$share_residual)
  )
  long$factor <- factor(long$factor, levels = c(
    "NONMEM version", "Ubuntu version", "gfortran version", "Architecture", "Residual"
  ))
  long$param_label <- factor(long$param_label, levels = rev(d$param_label))

  ggplot(long, aes(y = param_label, x = share, fill = factor)) +
    geom_col() +
    scale_x_continuous(labels = scales::percent_format(accuracy = 1)) +
    scale_fill_brewer(palette = "Set2") +
    labs(
      x = "Share of variance",
      y = NULL,
      fill = NULL,
      title = sprintf("Variance attribution (top %d most variable parameters)",
                      nrow(d))
    ) +
    theme_minimal(base_size = 8) +
    theme(axis.text.y = element_text(size = 6))
}

# ---------------------------------------------------------------------------
# Convergence matrix: ctl × tag, fill = converged or failed. Quick visual
# of *which* combinations even produced a result.
plot_convergence <- function(df) {
  one_per <- unique(df[, c("tag", "ctl", "converged", "nm_version")])
  if (nrow(one_per) == 0L) return(ggplot() + labs(title = "(no convergence data)"))

  one_per$status <- ifelse(one_per$converged, "converged", "failed")

  ggplot(one_per, aes(x = tag, y = ctl, fill = status)) +
    geom_tile() +
    scale_fill_manual(values = c(converged = "#2C7BB6", failed = "#D7191C")) +
    labs(
      x = "Image tag",
      y = "CTL file",
      fill = NULL,
      title = "Convergence by (CTL × image tag)"
    ) +
    theme_minimal(base_size = 8) +
    theme(
      axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5, size = 4),
      axis.text.y = element_text(size = 5)
    )
}

# Convenience: %||% (also defined in extract_lst.R; safe to redefine).
`%||%` <- function(a, b) if (is.null(a)) b else a
