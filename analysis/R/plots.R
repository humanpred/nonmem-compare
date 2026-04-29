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
# OFV per CTL across tags: deviations from per-CTL median, on a chi-squared
# (df=1) scale. Reference dashed lines mark the standard LRT thresholds:
# 3.84 (p=0.05), 6.63 (p=0.01), 10.83 (p=0.001). Any systematic delta for
# the same model on the same data is purely numerical, but these thresholds
# tell us whether the disagreement would alter a typical nested-model
# comparison.
plot_ofv_distribution <- function(df) {
  ofv_df <- unique(df[, c("tag", "ctl", "ofv", "converged",
                          "nm_version", "arch")])
  ofv_df <- ofv_df[ofv_df$converged & is.finite(ofv_df$ofv), , drop = FALSE]
  if (nrow(ofv_df) == 0L) return(ggplot() + labs(title = "(no converged OFV data)"))

  med <- ave(ofv_df$ofv, ofv_df$ctl, FUN = function(x) median(x, na.rm = TRUE))
  ofv_df$ofv_delta <- ofv_df$ofv - med

  # Symmetric chi-squared reference lines.
  thresholds <- data.frame(
    y = c(3.84, 6.63, 10.83, -3.84, -6.63, -10.83),
    label = c("3.84 (p=0.05)", "6.63 (p=0.01)", "10.83 (p=0.001)",
              "", "", "")
  )

  ggplot(ofv_df, aes(x = ctl, y = ofv_delta)) +
    geom_hline(data = thresholds, aes(yintercept = y),
               linetype = "dashed", colour = "grey60", linewidth = 0.3) +
    geom_jitter(aes(colour = nm_version, shape = arch),
                width = 0.2, height = 0, size = 1.2, alpha = 0.7) +
    geom_boxplot(outlier.shape = NA, fill = NA) +
    scale_colour_viridis_d(option = "plasma", end = 0.9) +
    labs(
      x = NULL,
      y = "OFV - median(OFV) per CTL  (chi-squared df=1 scale)",
      title = "OFV variability across image variants",
      subtitle = "Dashed lines mark p=0.05 (3.84), p=0.01 (6.63), p=0.001 (10.83)",
      colour = "NONMEM\nversion",
      shape = "Arch"
    ) +
    theme_minimal(base_size = 9) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 6))
}

# ---------------------------------------------------------------------------
# Per-CTL reproducibility scoreboard: stacked bar of tier proportions per
# CTL, sorted by pct_good ascending so the least-reproducible CTLs appear
# first. Useful for spotting which models are noisy across versions.
plot_ctl_reproducibility <- function(df, top_n = 50L) {
  d <- df[!is.na(df$tier) & df$param_type %in%
            c("theta", "omega", "sigma", "eta_shrinkage"), , drop = FALSE]
  if (nrow(d) == 0L) return(ggplot() + labs(title = "(no data)"))

  d$tier <- factor(d$tier, levels = DIFF_TIERS)
  tab <- as.data.frame(table(ctl = d$ctl, tier = d$tier),
                       stringsAsFactors = FALSE)
  total <- ave(tab$Freq, tab$ctl, FUN = sum)
  tab$prop <- ifelse(total > 0, tab$Freq / total, 0)

  # Order CTLs by share of (identical + noise) ascending.
  good_share <- aggregate(
    Freq ~ ctl,
    data = subset(tab, tier %in% c("identical", "noise")),
    FUN = sum
  )
  total_per_ctl <- aggregate(Freq ~ ctl, data = tab, FUN = sum)
  scores <- merge(good_share, total_per_ctl, by = "ctl",
                  suffixes = c("_good", "_tot"))
  scores$pct_good <- 100 * scores$Freq_good / scores$Freq_tot
  scores <- scores[order(scores$pct_good), ]
  if (nrow(scores) > top_n) scores <- scores[seq_len(top_n), ]

  tab <- tab[tab$ctl %in% scores$ctl, ]
  tab$ctl <- factor(tab$ctl, levels = rev(scores$ctl))
  tab$tier <- factor(tab$tier, levels = rev(DIFF_TIERS))

  ggplot(tab, aes(y = ctl, x = prop, fill = tier)) +
    geom_col() +
    scale_x_continuous(labels = scales::percent_format(accuracy = 1)) +
    scale_fill_manual(values = TIER_PALETTE, drop = FALSE,
                      breaks = DIFF_TIERS) +
    labs(
      x = "Share of parameter cells",
      y = NULL,
      fill = "Tier",
      title = sprintf("Per-CTL reproducibility (top %d least reproducible)",
                      nrow(scores))
    ) +
    theme_minimal(base_size = 8) +
    theme(axis.text.y = element_text(size = 6))
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
# Variance decomposition stacked bars, facetted by param_type so each type
# (theta / omega / eta_shrinkage / epsilon_shrinkage) gets its own panel.
# Within each panel, rows = (ctl, param_name) sorted by total across-tag
# variance descending; up to `top_n` per panel.
plot_variance_decomp <- function(decomp_df, top_n = 20L) {
  d <- decomp_df[is.finite(decomp_df$var_total) & decomp_df$var_total > 0, , drop = FALSE]
  if (nrow(d) == 0L) return(ggplot() + labs(title = "(no decomposable variance)"))

  # Keep top_n most variable per param_type
  d <- do.call(rbind, lapply(split(d, d$param_type), function(sub) {
    sub <- sub[order(-sub$var_total), , drop = FALSE]
    head(sub, top_n)
  }))
  d$param_label <- paste(d$ctl, d$param_name, sep = " : ")

  factor_levels <- c("NONMEM version", "Ubuntu version", "gfortran version",
                     "Architecture", "Residual")
  long <- data.frame(
    param_type  = rep(d$param_type, 5),
    param_label = rep(d$param_label, 5),
    factor      = rep(factor_levels, each = nrow(d)),
    share       = c(d$share_nm_version, d$share_ubuntu_version,
                    d$share_gfortran_version, d$share_arch, d$share_residual),
    stringsAsFactors = FALSE
  )
  long$factor <- factor(long$factor, levels = factor_levels)
  # Sort each panel by total variance: build a global ordering that preserves
  # within-type rank, then apply as factor levels.
  ordered_labels <- d$param_label  # already in within-type variance order
  long$param_label <- factor(long$param_label, levels = rev(ordered_labels))

  ggplot(long, aes(y = param_label, x = share, fill = factor)) +
    geom_col() +
    facet_wrap(~ param_type, scales = "free_y", ncol = 1) +
    scale_x_continuous(labels = scales::percent_format(accuracy = 1)) +
    scale_fill_brewer(palette = "Set2") +
    labs(
      x = "Share of variance",
      y = NULL,
      fill = NULL,
      title = sprintf("Variance attribution (up to %d most variable parameters per type)",
                      top_n)
    ) +
    theme_minimal(base_size = 8) +
    theme(axis.text.y = element_text(size = 6),
          strip.text  = element_text(size = 9, face = "bold"))
}

# ---------------------------------------------------------------------------
# Per-parameter-type aggregate: show the median factor share with IQR
# as horizontal error-bar-style points. Single panel summarises the
# central question "for this class of parameter, which factor explains
# the most?"
plot_variance_by_type <- function(by_type_df) {
  if (nrow(by_type_df) == 0L) return(ggplot() + labs(title = "(no data)"))

  factors <- c(
    NM_version       = "share_nm_version",
    Ubuntu_version   = "share_ubuntu_version",
    gfortran_version = "share_gfortran_version",
    Architecture     = "share_arch",
    Residual         = "share_residual"
  )
  rows <- list()
  for (i in seq_len(nrow(by_type_df))) {
    for (lbl in names(factors)) {
      stem <- factors[[lbl]]
      rows[[length(rows) + 1L]] <- data.frame(
        param_type = by_type_df$param_type[i],
        n_params   = by_type_df$n_params[i],
        factor     = lbl,
        median     = by_type_df[[paste0(stem, "_median")]][i],
        q25        = by_type_df[[paste0(stem, "_q25")]][i],
        q75        = by_type_df[[paste0(stem, "_q75")]][i],
        stringsAsFactors = FALSE
      )
    }
  }
  long <- do.call(rbind, rows)
  long$factor <- factor(long$factor, levels = names(factors))

  ggplot(long, aes(x = median, y = factor, colour = param_type)) +
    geom_errorbarh(aes(xmin = q25, xmax = q75),
                   position = position_dodge(width = 0.6),
                   height = 0, linewidth = 0.4) +
    geom_point(position = position_dodge(width = 0.6), size = 2.5) +
    scale_x_continuous(labels = scales::percent_format(accuracy = 1)) +
    scale_colour_brewer(palette = "Dark2") +
    labs(
      x = "Median share of variance (bars = IQR)",
      y = NULL,
      colour = "param type",
      title = "Variance attribution by parameter type"
    ) +
    theme_minimal(base_size = 9)
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
