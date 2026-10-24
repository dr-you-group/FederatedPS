source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
meta <- readRDS(file.path(FP_OUT, "statin3/meta.rds")); axis <- meta$axis; d <- meta$d
SITES <- meta$sites
S <- lapply(SITES, function(nm){ dd <- readRDS(sprintf(file.path(FP_OUT, "sitedata/tri/%s.rds"), nm))
  j <- match(as.numeric(colnames(dd$x)), axis); t <- Matrix::summary(as(dd$x,"TsparseMatrix"))
  Xg <- sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(nrow(dd$x), length(axis)))
  list(Xg=as(cbind(Matrix(1,nrow(Xg),1,sparse=TRUE),Xg),"CsparseMatrix"), y=dd$treatment) })
X <- do.call(rbind, lapply(S,`[[`,"Xg")); y <- unlist(lapply(S,`[[`,"y"))
site <- rep(SITES, sapply(S, function(s) nrow(s$Xg))); Z <- X[,-1,drop=FALSE]; K <- 3L
cat(sprintf("pooled %d x %d ; alpha* = %.4f\n", nrow(X), ncol(X), meta$alphaStar))
CFG <- list(c(1,1), c(20,meta$alphaStar), c(20,0.7), c(20,0.5), c(20,0.3), c(50,0.5))
ref <- NULL; rows <- list()
for (cf in CFG) {
  P <- as.integer(cf[1]); a <- cf[2]
  r <- runCfg(X, y, P=P, alpha=a); m <- metrics(r$beta, X, y)
  if (is.null(ref)) ref <- list(beta=r$beta, m=m, R=r$R_loop)
  mm <- matchPs(m$ps, y); bal <- smdStats(Z, y, mm$idx)
  mi <- which(site=="ehrshot"); mmE <- matchPs(m$ps[mi], y[mi])
  balE <- smdStats(Z[mi,,drop=FALSE], y[mi], mmE$idx)
  rows[[length(rows)+1L]] <- data.frame(P=P, alpha=a, flag=r$flag, passes=r$passes,
    blocksPerPass=r$blocksPerPass, R_loop=r$R_loop, R_overhead=r$R_overhead,
    reduction=ref$R/r$R_loop, MB=bytesOf(r,K)/1e6, localSecs=r$localSeconds,
    objective=m$obj, relObjGap=(m$obj-ref$m$obj)/abs(ref$m$obj), kkt=m$kkt, nnz=m$nnz,
    supportDiff=length(union(setdiff(which(ref$beta!=0),which(r$beta!=0)),
                             setdiff(which(r$beta!=0),which(ref$beta!=0)))),
    psCor=cor(m$ps, ref$m$ps), maxPSdiff=max(abs(m$ps-ref$m$ps)),
    pooledPairs=mm$pairs, pooledMeanSMD=bal$summary["mean"], pooled_gt0.1=bal$summary["n_gt_0.1"],
    ehrshotPairs=mmE$pairs, ehrshotMeanSMD=balE$summary["mean"], ehrshot_gt0.1=balE$summary["n_gt_0.1"])
  cat(sprintf("  P=%-3d a=%-6.4f passes=%-4d R_loop=%-9s red=%5.1fx objGap=%+.2e kkt=%7.2f nnz=%-6d | pooledSMD=%.5f  ehrshotSMD=%.4f(%d pairs)\n",
    P, a, r$passes, format(r$R_loop, big.mark=","), ref$R/r$R_loop,
    (m$obj-ref$m$obj)/abs(ref$m$obj), m$kkt, m$nnz, bal$summary["mean"],
    balE$summary["mean"], mmE$pairs))
}
tab <- do.call(rbind, rows); rownames(tab) <- NULL
write.csv(tab, file.path(FP_OUT, "statin3/tables/table2_sweep.csv"), row.names=FALSE)
saveRDS(list(tab=tab, refBeta=ref$beta, psRef=ref$m$ps, y=y, site=site), file.path(FP_OUT, "statin3/sweep.rds"))
cat("\nsweep complete\n")
