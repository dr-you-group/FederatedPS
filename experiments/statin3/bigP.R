## Block size up to P = d. With P = d a pass is one block plus one convergence exchange.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
meta <- readRDS(file.path(FP_OUT, "statin3/meta.rds")); axis <- meta$axis; d <- meta$d; SITES <- meta$sites
om <- meta$omega_global
S <- lapply(SITES, function(nm){ dd <- readRDS(sprintf(file.path(FP_OUT, "sitedata/tri/%s.rds"), nm))
  j <- match(as.numeric(colnames(dd$x)), axis); t <- Matrix::summary(as(dd$x,"TsparseMatrix"))
  Xg <- sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(nrow(dd$x), length(axis)))
  list(Xg=as(cbind(Matrix(1,nrow(Xg),1,sparse=TRUE),Xg),"CsparseMatrix"), y=dd$treatment) })
X <- do.call(rbind, lapply(S,`[[`,"Xg")); y <- unlist(lapply(S,`[[`,"y"))
site <- rep(SITES, sapply(S, function(s) nrow(s$Xg))); Z <- X[,-1,drop=FALSE]; K <- 3L
eso <- function(P) 1/(1 + (P-1)*(om-1)/(d-1))
ref <- runCfg(X, y, P=1L, alpha=1); mR <- metrics(ref$beta, X, y)
cat(sprintf("exact reference: passes=%d R_loop=%d obj=%.4f kkt=%.2f nnz=%d\n\n",
            ref$passes, ref$R_loop, mR$obj, mR$kkt, mR$nnz))
## Start from gamma times the ESO bound and halve alpha after a curvature error.
GAMMA <- 0.4
CFG <- c(50L, 100L, 200L, 500L, 1000L, 2000L, 5000L, 10000L, as.integer(d))
rows <- list()
for (P in CFG) {
  a <- min(0.5, GAMMA * eso(P)); r <- NULL
  for (attempt in 1:5) {
    r <- tryCatch(runCfg(X, y, P=P, alpha=a, maxIterations=4000L),
                  error=function(e) {cat(sprintf("    P=%d a=%.5f failed: %s\n", P, a, substr(conditionMessage(e),1,45))); NULL})
    if (!is.null(r)) break
    a <- a/2
  }
  if (is.null(r)) { cat(sprintf("P=%-6d no alpha worked\n", P)); next }
  m <- metrics(r$beta, X, y)
  mm <- matchPs(m$ps, y); bal <- smdStats(Z, y, mm$idx)
  ii <- which(site=="ehrshot"); mmE <- matchPs(m$ps[ii], y[ii])
  balE <- smdStats(Z[ii,,drop=FALSE], y[ii], mmE$idx)
  rows[[length(rows)+1L]] <- data.frame(P=P, alpha=a, esoAlpha=eso(P), flag=r$flag,
    passes=r$passes, blocksPerPass=r$blocksPerPass, R_loop=r$R_loop,
    reduction=ref$R_loop/r$R_loop, MB=bytesOf(r,K)/1e6, secs=round(r$localSeconds,1),
    objective=m$obj, relObjGap=(m$obj-mR$obj)/abs(mR$obj), kkt=m$kkt, nnz=m$nnz,
    psCor=cor(m$ps, mR$ps), maxPSdiff=max(abs(m$ps-mR$ps)),
    pooledSMD=bal$summary["mean"], pooled_gt0.1=bal$summary["n_gt_0.1"],
    ehrshotSMD=balE$summary["mean"])
  cat(sprintf("P=%-6d a=%-7.4f passes=%-5d R_loop=%-8s red=%7.1fx objGap=%+.3e kkt=%8.2f nnz=%-6d psCor=%.5f %.0fs\n",
      P, a, r$passes, format(r$R_loop, big.mark=","), ref$R_loop/r$R_loop,
      (m$obj-mR$obj)/abs(mR$obj), m$kkt, m$nnz, cor(m$ps,mR$ps), r$localSeconds)); flush(stdout())
}
tab <- do.call(rbind, rows); rownames(tab) <- NULL
write.csv(tab, file.path(FP_OUT, "statin3/tables/table10_bigP.csv"), row.names=FALSE)
print(tab[,c("P","alpha","passes","R_loop","reduction","relObjGap","kkt","nnz","psCor","pooledSMD")],
      row.names=FALSE, digits=4)
