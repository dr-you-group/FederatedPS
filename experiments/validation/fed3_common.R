## Minimal file-exchange federation with the R/Pda.R semantics, extended to block packets.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
put <- function(v, name, dir) {
  saveRDS(v, file.path(dir, paste0(name, ".rds")))
  file.create(file.path(dir, paste0(name, "_ready")))      # announce after write
}
get1 <- function(name, dir, timeout = 300) {
  dl <- Sys.time() + timeout
  while (!file.exists(file.path(dir, paste0(name, "_ready")))) {
    if (Sys.time() >= dl) stop("timeout waiting for ", name); Sys.sleep(0.001) }
  readRDS(file.path(dir, paste0(name, ".rds")))
}

## Summed and shared index ranges for a packet of width w:
##   summed <- 1:(2w), shared <- (2w+1):(4w); w = 1 gives the scalar layout 1:2 / 3:4.
aggregateBlock <- function(dir, sites, timeout = 300) {
  round <- 0L; nRound <- 0L
  repeat {
    key <- paste0("r", round)
    vals <- lapply(sites, function(s) get1(paste0(key, "_", s), dir, timeout))
    first <- vals[[1L]]
    coordinate <- attr(first, "coordinate")
    if (coordinate == -99L) { put(TRUE, paste0(key, "_total"), dir); break }
    if (coordinate == 0L) { summed <- 1L; shared <- 2L
    } else { w <- length(first) %/% 4L; summed <- seq_len(2L*w); shared <- (2L*w+1L):(4L*w) }
    result <- first; result[summed] <- 0
    for (v in vals) {
      if (!identical(attr(v, "coordinate"), coordinate)) stop("Hospital coordinate states differ")
      if (any(!is.finite(v))) stop("Non-finite hospital statistics")
      if (any(v[shared] != first[shared])) stop("Hospital coefficient or prior states differ")
      result[summed] <- result[summed] + v[summed]       # sum of the local sums
    }
    put(as.vector(result), paste0(key, "_total"), dir)
    round <- round + 1L; nRound <- nRound + 1L
  }
  nRound
}
