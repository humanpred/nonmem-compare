# parse_tag.R — Parse a result tag string into its constituent metadata.
#
# Tag format (from the build_matrix.sh / Makefile naming convention):
#   {NM_VERSION}-ubuntu{UBUNTU_VERSION}-gfortran{GFORTRAN_VERSION}-{ARCH}
# Examples:
#   "7.5.1-ubuntu24.04-gfortran12-arm64"
#   "7.6.0-ubuntu22.04-gfortran9-amd64"
#   "7.2.0-ubuntu14.04-gfortran4.8-amd64"  (NB: gfortran can have a dotted version)

#' Parse a NONMEM compare tag into its constituent fields.
#'
#' @param tag Character vector of tag strings.
#' @return A data.frame with columns: tag, nm_version, ubuntu_version,
#'   gfortran_version, arch. Rows where the tag does not match the expected
#'   pattern get NA in all parsed columns.
parse_tag <- function(tag) {
  # gfortran version may be plain integer (e.g. "9", "12") or dotted (e.g. "4.8").
  # arch is the final segment, always amd64 / arm64 / arm in our matrix.
  pattern <- "^(\\d+\\.\\d+\\.\\d+)-ubuntu(\\d+\\.\\d+)-gfortran(\\d+(?:\\.\\d+)?)-(amd64|arm64|arm)$"

  m <- regmatches(tag, regexec(pattern, tag, perl = TRUE))

  out <- data.frame(
    tag = tag,
    nm_version       = NA_character_,
    ubuntu_version   = NA_character_,
    gfortran_version = NA_character_,
    arch             = NA_character_,
    stringsAsFactors = FALSE
  )

  for (i in seq_along(m)) {
    if (length(m[[i]]) >= 5L) {
      out$nm_version[i]       <- m[[i]][2]
      out$ubuntu_version[i]   <- m[[i]][3]
      out$gfortran_version[i] <- m[[i]][4]
      out$arch[i]             <- m[[i]][5]
    }
  }
  out
}
