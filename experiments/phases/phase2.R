## Phase 2: sensitivity to the block size P and damping alpha (MIMIC, K = 2).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
set.seed(20260921)
D <- loadDesign("mimic")
X <- onAxis(D, D$feat); y <- D$y
## the K=2 split defines which columns are globally non-zero (d = 9,812)
g <- sample(rep(1:2, length.out = nrow(X)))
present <- Reduce(`|`, lapply(1:2, function(k) colSums(X[g == k, , drop = FALSE] != 0) > 0))
present[1] <- TRUE
X <- X[, present, drop = FALSE]; d <- ncol(X); Z <- X[, -1, drop = FALSE]
nk <- c(sum(g == 1), sum(g == 2)); K <- 2L
omega <- max(rowSums(X != 0))                      # max non-zeros per row, incl. intercept
eso <- function(P) 1 / (1 + (P - 1) * (omega - 1) / (d - 1))
cat(sprintf("d = %d ; K = %d (%d / %d) ; omega = %d ; omega/d = %.4f\n",
            d, K, nk[1], nk[2], omega, omega / d))
cat(sprintf("ESO alpha*: P=5 %.3f  P=10 %.3f  P=20 %.3f  P=50 %.3f  P=100 %.3f\n",
            eso(5), eso(10), eso(20), eso(50), eso(100)))
MS_PER_ROUND <- 649.7 / 85117                       # measured on this host, K=2, tmpfs

CFG <- list(list(1L, 1.00, "exact baseline"), list(5L, round(eso(5), 3), "ESO alpha*"),
            list(10L, 0.50, "fixed"), list(20L, 0.05, "1/P heuristic"),
            list(20L, 0.52, "first validated conservative"), list(20L, 0.70, "above 0.52"),
            list(20L, 0.80, "near ESO alpha*"), list(50L, 0.29, "ESO-scaled"),
            list(100L, 0.17, "ESO-scaled"))
ref <- NULL; out <- list()
for (cfg in CFG) {
  P <- cfg[[1]]; a <- cfg[[2]]
  r <- runCfg(X, y, P = P, alpha = a)
  m <- metrics(r$beta, X, y)
  if (is.null(ref)) { ref <- list(beta = r$beta, m = m, R = r$R_loop) }
  mm <- matchPs(m$ps, y); bal <- smdStats(Z, y, mm$idx)
  out[[length(out) + 1L]] <- data.frame(
    P = P, alpha = a, note = cfg[[3]], diverged = r$diverged, flag = r$flag,
    passes = r$passes, blocksPerPass = r$blocksPerPass,
    R_loop_formula = r$R_loop_formula, R_loop = r$R_loop,
    finalConvExchange = r$convExchanges - r$passes, R_overhead = r$R_overhead,
    R_total = r$R_total, reduction = ref$R / r$R_loop,
    MB = bytesOf(r, K) / 1e6,
    commSecs_model = r$R_loop * MS_PER_ROUND, localSecs = r$localSeconds,
    objective = m$obj, objGapRel = (m$obj - ref$m$obj) / abs(ref$m$obj),
    kkt = m$kkt, nnz = m$nnz,
    supportDiff = length(union(setdiff(which(ref$beta != 0), which(r$beta != 0)),
                               setdiff(which(r$beta != 0), which(ref$beta != 0)))),
    maxCoefDiff = max(abs(r$beta - ref$beta)),
    psCor = cor(m$ps, ref$m$ps), maxPSdiff = max(abs(m$ps - ref$m$ps)),
    matchedPairs = mm$pairs,
    meanSMD = bal$summary["mean"], maxSMD = bal$summary["max"],
    n_gt_0.1 = bal$summary["n_gt_0.1"])
  cat(sprintf("  P=%-4d a=%-5.2f %-28s passes=%-4d R_loop=%-9s red=%5.1fx objGap=%+.2e kkt=%7.2f nnz=%-5d meanSMD=%.5f\n",
      P, a, cfg[[3]], r$passes, format(r$R_loop, big.mark = ","), ref$R / r$R_loop,
      (m$obj - ref$m$obj) / abs(ref$m$obj), m$kkt, m$nnz, bal$summary["mean"]))
}
tab <- do.call(rbind, out); rownames(tab) <- NULL
write.csv(tab, file.path(FP_OUT, "phases/tables/phase2_sensitivity.csv"), row.names = FALSE)
saveRDS(list(tab = tab, omega = omega, d = d, eso = sapply(c(1,5,10,20,50,100), eso)),
        file.path(FP_OUT, "phases/phase2.rds"))
cat("\nPhase 2 complete.\n")
