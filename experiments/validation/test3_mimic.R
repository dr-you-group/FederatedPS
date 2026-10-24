source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "validation/common.R")); useCyclops("patched")
lam <- lambdaOf(1); K <- 2L
dd <- readRDS(file.path(FP_DATA, "statin/mimic/design.rds"))
rows <- sort(dd$rowId); feat <- dd$covariateIds
i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat); ok <- !is.na(i)&!is.na(j)
Xs <- sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok], dims=c(length(rows),length(feat)))
Xs <- as(cbind(Matrix(1,length(rows),1,sparse=TRUE), Xs), "CsparseMatrix")
y  <- dd$treatment[match(rows, dd$rowId)]
set.seed(20260921); grp <- sample(rep(1:2, length.out=nrow(Xs)))
present <- Reduce(`|`, lapply(1:2, function(k) colSums(Xs[grp==k,,drop=FALSE]!=0)>0)); present[1] <- TRUE
X <- Xs[, present, drop=FALSE]; d <- ncol(X)
cat(sprintf("mimic K=2  site sizes %d / %d   d = %d   nnz = %d\n",
            sum(grp==1), sum(grp==2), d, length(X@x)))

CFG <- list(c(1,1), c(20,0.05), c(20,0.52), c(50,0.29), c(100,0.17))
res <- list(); base <- NULL
for (cfg in CFG) {
  P <- as.integer(cfg[1]); a <- cfg[2]
  r <- suppressWarnings(runFit(X, y, P = P, alpha = a, variance = 1,
                               tol = 1e-6, maxIterations = 1000L, aggregate = TRUE))
  st <- pooledStats(r$beta, X, y, lam)
  if (is.null(base)) { base <- list(beta = r$beta, st = st, comm = r$rec$n, wall = r$wall) }
  blocksPass <- ceiling(d / P); S <- r$iterations
  res[[length(res)+1L]] <- data.frame(
    P = P, alpha = a, flag = r$flag, passes = S,
    blocksPerPass = blocksPass, convPerPass = 1L,
    R_loop_formula = (blocksPass + 1L) * S,
    R_loop_measured = r$rec$n, R_overhead = 3L,
    MB = round(wireBytes(r$rec, K)/1e6, 2),
    commSecs_model = round(r$rec$n * MS_PER_ROUND, 1),
    localSecs = round(r$wall - r$rec$tAgg, 2),
    callbackSecs = round(r$rec$tAgg, 2),
    obj = st$obj, relObjGap = (st$obj - base$st$obj)/abs(base$st$obj),
    kkt = st$kkt, gradNorm = st$gradNorm, nnz = st$nnz,
    maxCoefDiff = max(abs(r$beta - base$beta)),
    maxPSdiff = max(abs(st$ps - base$st$ps)),
    diverged = !all(is.finite(r$beta)) || r$flag != "SUCCESS")
  cat(sprintf("  P=%-4d a=%-5.2f  S=%-4d  exch=%-9s  obj=%.4f  nnz=%-5d  relGap=%+.2e  maxPS=%.4f  %.1fs\n",
      P, a, S, format(r$rec$n, big.mark=","), st$obj, st$nnz,
      (st$obj-base$st$obj)/abs(base$st$obj), max(abs(st$ps-base$st$ps)), r$wall))
}
out <- do.call(rbind, res)
out$commReduction <- round(out$R_loop_measured[1] / out$R_loop_measured, 1)

## IPTW standardised mean differences against the exact baseline PS
Z <- X[,-1,drop=FALSE]; Z2 <- Z; Z2@x <- Z2@x^2
smd <- function(ps) {
  ps <- pmin(pmax(ps,1e-6),1-1e-6); w <- ifelse(y==1, 1/ps, 1/(1-ps))
  w1 <- w*(y==1); w0 <- w*(y==0); s1 <- sum(w1); s0 <- sum(w0)
  m1 <- as.vector(crossprod(Z,w1))/s1; m0 <- as.vector(crossprod(Z,w0))/s0
  v1 <- as.vector(crossprod(Z2,w1))/s1 - m1^2; v0 <- as.vector(crossprod(Z2,w0))/s0 - m0^2
  sd <- sqrt(pmax((v1+v0)/2,0)); k <- sd > 1e-8; dv <- abs(m1-m0)[k]/sd[k]
  c(meanSMD = mean(dv), maxSMD = max(dv), nOver0.1 = sum(dv > 0.1))
}
sm <- t(sapply(seq_along(CFG), function(i) {
  P <- as.integer(CFG[[i]][1]); a <- CFG[[i]][2]
  r <- suppressWarnings(runFit(X, y, P=P, alpha=a, tol=1e-6, maxIterations=1000L, aggregate=TRUE))
  smd(pooledStats(r$beta, X, y, lam)$ps) }))
out <- cbind(out, sm)
write.csv(out, file.path(FP_OUT, "validation/test3_mimic.csv"), row.names = FALSE)
cat("\n"); print(out[, c("P","alpha","passes","R_loop_measured","commReduction","relObjGap",
                         "kkt","nnz","maxPSdiff","meanSMD","maxSMD","nOver0.1","diverged")],
                 row.names = FALSE, digits = 4)
