## Phase 3: compare the federated runs across partitions and against the pooled fits.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
PL <- readRDS(file.path(FP_OUT, "phases/phase3_pooled.rds"))
X <- as(cbind(Matrix(1, nrow(PL$X), 1, sparse = TRUE), PL$X), "CsparseMatrix")
y <- PL$y; Z <- X[, -1, drop = FALSE]
## pooled single-process references
ref1 <- runCfg(X, y, P = 1L, alpha = 1);      m1 <- metrics(ref1$beta, X, y)
ref20 <- runCfg(X, y, P = 20L, alpha = 0.062); m20 <- metrics(ref20$beta, X, y)
mm1 <- matchPs(m1$ps, y); bal1 <- smdStats(Z, y, mm1$idx)
cat(sprintf("pooled single process: P=1 passes %d rounds %d nnz %d | P=20 passes %d rounds %d nnz %d\n",
            ref1$passes, ref1$R_loop, m1$nnz, ref20$passes, ref20$R_loop, m20$nnz))
parts <- read.csv(file.path(FP_OUT, "phases/tables/phase3_partitions.csv"))
rows <- list()
for (S in c("A","B","C","D","E")) {
  pinfo <- parts[parts$setting == paste0("p3", S), ]
  for (P in c(1L, 20L)) {
    run <- sprintf("p3%sP%d", S, P)
    f <- sprintf(file.path(FP_OUT, "fedruns/%s/agg.rds"), run)
    if (!file.exists(f)) { cat(sprintf("  %s: MISSING\n", run)); next }
    a <- readRDS(f); b <- unname(a$coefficients)
    sites <- lapply(sprintf(file.path(FP_OUT, "fedruns/%s/s%d.rds"), run, 1:3), readRDS)
    ident <- all(sapply(sites, function(s) identical(unname(s$coefficients), b)))
    ref <- if (P == 1L) ref1 else ref20; mref <- if (P == 1L) m1 else m20
    m <- metrics(b, X, y)
    mm <- matchPs(m$ps, y); bal <- smdStats(Z, y, mm$idx)
    rows[[length(rows)+1L]] <- data.frame(setting = S, P = P,
      sizes = paste(pinfo$n, collapse = "/"),
      prevalence = paste(sprintf("%.2f", pinfo$prevalence), collapse = "/"),
      meanBurden = paste(sprintf("%.0f", pinfo$meanBurden), collapse = "/"),
      passes = sites[[1]]$iterations, R_loop = sites[[1]]$loopRounds,
      R_overhead = sites[[1]]$overheadRounds,
      reduction = ref1$R_loop / sites[[1]]$loopRounds,
      sitesIdentical = ident,
      objGapRelVsExact = (m$obj - m1$obj) / abs(m1$obj), kkt = m$kkt, nnz = m$nnz,
      supportDiffVsExact = length(union(setdiff(which(ref1$beta != 0), which(b != 0)),
                                        setdiff(which(b != 0), which(ref1$beta != 0)))),
      psCorVsExact = cor(m$ps, m1$ps),
      fedVsSingleMaxDiff = max(abs(b - ref$beta)),
      fedVsSingleRelErr = sqrt(sum((b - ref$beta)^2)) / sqrt(sum(ref$beta^2)),
      matchedPairs = mm$pairs, meanSMD = bal$summary["mean"],
      n_gt_0.1 = bal$summary["n_gt_0.1"])
    cat(sprintf("  %s P=%-3d sizes %-18s prev %-14s | passes %-4d rounds %-6d sitesIdent %-5s fedVsSingle %.2e objGap %+.2e nnz %d\n",
        S, P, paste(pinfo$n, collapse="/"), paste(sprintf("%.2f",pinfo$prevalence), collapse="/"),
        sites[[1]]$iterations, sites[[1]]$loopRounds, ident,
        max(abs(b - ref$beta)), (m$obj - m1$obj)/abs(m1$obj), m$nnz))
  }
}
tab <- do.call(rbind, rows); rownames(tab) <- NULL
write.csv(tab, file.path(FP_OUT, "phases/tables/phase3_noniid.csv"), row.names = FALSE)
## cross-setting identity
for (P in c(1L, 20L)) {
  bs <- lapply(c("A","B","C","D","E"), function(S) {
    f <- sprintf(file.path(FP_OUT, "fedruns/p3%sP%d/agg.rds"), S, P)
    if (file.exists(f)) unname(readRDS(f)$coefficients) else NULL })
  bs <- Filter(Negate(is.null), bs)
  if (length(bs) > 1) {
    mx <- max(sapply(bs[-1], function(b) max(abs(b - bs[[1]]))))
    cat(sprintf("\nP=%d : coefficients across the %d heterogeneity settings -- all identical: %s ; max|diff| = %.3e\n",
        P, length(bs), all(sapply(bs[-1], function(b) identical(b, bs[[1]]))), mx))
  }
}
saveRDS(tab, file.path(FP_OUT, "phases/phase3.rds"))
cat("\nPhase 3 verification complete.\n")
