## Summary of the federated cross-validation runs.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
S <- file.path(FP_OUT, "fedcv")
L <- lapply(list.files(S, pattern = "_summary\\.csv$", full.names = TRUE), read.csv)
sm <- do.call(rbind, lapply(L, `[`, Reduce(intersect, lapply(L, names))))
sm$xCold <- (sm$roundsCV_cold + sm$roundsFinal_cold) / sm$roundsSingleFL
sm$xWarm <- (sm$roundsCV_warm + sm$roundsFinal_warm) / sm$roundsSingleFL
sm$saving <- 1 - sm$xWarm / sm$xCold
sm$vMatch <- sm$vFedCold == sm$vCenCold & sm$vFedCold == sm$vFedWarm
sm$gapOverCkks <- sm$gapTop2 / 1.23e-8 / 3          # CKKS aggregation error bound per site (Phase 4), three sites
cat(sprintf("%d study\n\n", nrow(sm)))
o <- sm[order(sm$n), c("study","n","d","vFedCold","vCenCold","vFedWarm","vAutoCyclops","maxAbsDecomp","gapTop2",
  "maxRelScoreCentral","maxRelScoreWarmCold","maxAbsPSFinalWarmCold","xCold","xWarm","saving")]
num <- sapply(o, is.numeric); o[num] <- lapply(o[num], signif, 3); print(o, row.names = FALSE)
cat(sprintf("\nselected v equal (federated = pooled = warm): %d/%d; max decomposition error %.1e; min top-2 score gap %.3f (%.1e x CKKS error)\n",
  sum(sm$vMatch), nrow(sm), max(sm$maxAbsDecomp), min(sm$gapTop2), min(sm$gapOverCkks)))
cat(sprintf("cold CV cost = %.1f x one fit (median, range %.1f-%.1f)\n", median(sm$xCold), min(sm$xCold), max(sm$xCold)))
cat(sprintf("warm CV cost = %.1f x one fit (median, range %.1f-%.1f), saving %.0f%% (range %.0f-%.0f%%)\n",
  median(sm$xWarm), min(sm$xWarm), max(sm$xWarm), 100*median(sm$saving), 100*min(sm$saving), 100*max(sm$saving)))
cat(sprintf("warm vs cold: max relative CV score difference %.1e, max final PS difference %.1e\n",
  max(sm$maxRelScoreWarmCold), max(sm$maxAbsPSFinalWarmCold)))
## passes per v, cold and warm
R <- do.call(rbind, lapply(list.files(S, pattern = "_runs\\.csv$", full.names = TRUE), function(f) { r <- read.csv(f); r[, intersect(names(r), c("study","scheme","v","fold","passes","rounds","nnz"))] }))
p <- aggregate(cbind(passes, nnz) ~ scheme + v, data = R, FUN = mean)
w <- reshape(p, idvar = "v", timevar = "scheme", direction = "wide")
cat("\nmean passes and nonzero coefficients per v:\n"); print(signif(w[order(w$v), ], 3), row.names = FALSE)
cat(sprintf("\nmedian fraction of nonzero coefficients (warm): %.1f%%\n",
  100 * median(R$nnz[R$scheme == "warm"] / sm$d[match(R$study[R$scheme == "warm"], sm$study)])))
