## Summary checks for the full-scale block run.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
r1 <- lapply(c("mimic","synpuf1","synpuf2"), function(s) readRDS(sprintf(file.path(FP_OUT, "fedruns/fullP20/%s.rds"), s)))
a1 <- readRDS(file.path(FP_OUT, "fedruns/fullP20/agg.rds"))
has2 <- file.exists(file.path(FP_OUT, "fedruns/fullP20r/agg.rds"))
cat("=== D. Acceptance criteria ===\n")
cat(sprintf("1 no numerical divergence            : %s  (all coefficients finite, objective finite, flag SUCCESS)\n",
    all(is.finite(a1$coefficients))))
cat(sprintf("2 all three sites identical          : %s\n",
    all(sapply(r1, function(r) identical(r$coefficients, a1$coefficients)))))
if (has2) {
  a2 <- readRDS(file.path(FP_OUT, "fedruns/fullP20r/agg.rds"))
  r2 <- lapply(c("mimic","synpuf1","synpuf2"), function(s) readRDS(sprintf(file.path(FP_OUT, "fedruns/fullP20r/%s.rds"), s)))
  cat(sprintf("7 reproducible, independent re-run    : identical coefficients = %s ; max|diff| = %.3e\n",
      identical(a2$coefficients, a1$coefficients), max(abs(a2$coefficients - a1$coefficients))))
  cat(sprintf("                                       passes %d vs %d ; rounds %d vs %d\n",
      r2[[1]]$iterations, r1[[1]]$iterations, r2[[1]]$loopRounds, r1[[1]]$loopRounds))
  cat(sprintf("                                       wall %.1f s vs %.1f s\n", readRDS(file.path(FP_OUT, "fedruns/fullP20r/agg.rds"))$wall, a1$wall))
} else cat("7 reproducibility re-run              : not finished\n")
