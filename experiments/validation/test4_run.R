source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))

suppressPackageStartupMessages({library(Cyclops); library(Matrix)})
source(file.path(FP_EXP, "validation/fed3_common.R"))
lam <- sqrt(2)
## fixed, unbalanced three-site partition
set.seed(404); nk <- c(A = 600L, B = 200L, C = 50L); d <- 30L
n <- sum(nk)
Xd <- matrix(rbinom(n*d, 1, 0.35), n, d)
y  <- rbinom(n, 1, 1/(1+exp(-(-0.3 + Xd %*% c(1.3,-1.0,0.8, rep(0, d-3))))))
grp <- rep(names(nk), nk)
keep <- colSums(Xd != 0) > 0                       # globally non-zero
Xd <- Xd[, keep, drop = FALSE]
X  <- cbind(1, Xd)
sites <- names(nk)
for (s in sites) stopifnot(length(unique(y[grp == s])) == 2)   # both classes present
cat(sprintf("three sites, unbalanced: %s  (ratio %.1f:1)   d = %d\n",
    paste(sprintf("%s=%d", sites, nk), collapse = ", "), max(nk)/min(nk), ncol(X)))

pooledFit <- function(P, alpha) {
  sx <- Matrix(X[,-1,drop=FALSE], sparse=TRUE); sx <- as(sx,"CsparseMatrix")
  colnames(sx) <- paste0("v", seq_len(ncol(sx)))
  cd <- createCyclopsData(treatment~1, data=data.frame(treatment=y), sx=sx,
                          modelType="lr", floatingPoint=64)
  cd$coefficientNames <- c("(Intercept)", colnames(sx))
  rec <- new.env(); rec$n <- 0L
  f <- function(coordinate, statistics) { rec$n <- rec$n + 1L; statistics }
  fit <- fitCyclopsModel(cd, prior=createPrior("laplace",variance=1,
           exclude="(Intercept)", useCrossValidation=FALSE),
    control=createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
                          aggregate=f, blockSize=P, alpha=alpha),
    startingCoefficients=rep(0, ncol(X)))
  list(beta=unname(stats::coef(fit)), iter=fit$iterations, rounds=rec$n)
}
obj <- function(b){ e<-as.vector(X%*%b); sum(log1p(exp(e))-y*e)+lam*sum(abs(b[-1])) }

for (cfg in list(c(1,1), c(10,0.5))) {
  P <- as.integer(cfg[1]); a <- cfg[2]
  dir <- file.path(tempdir(), sprintf("fed3_P%d_a%s", P, a)); unlink(dir, recursive=TRUE); dir.create(dir, recursive=TRUE)
  Xl <- lapply(sites, function(s) X[grp==s,,drop=FALSE]); names(Xl) <- sites
  yl <- lapply(sites, function(s) y[grp==s]); names(yl) <- sites
  saveRDS(list(X=Xl, y=yl), file.path(dir, "data.rds"))
  for (s in sites) system2("Rscript", c(file.path(FP_EXP, "validation/test4_site.R"), s, dir, P, a),
                           wait=FALSE, stdout=file.path(dir, paste0(s,".log")), stderr=file.path(dir, paste0(s,".log")))
  nR <- aggregateBlock(dir, sites)
  dl <- Sys.time() + 120                                   # join the site processes
  repeat {
    if (all(file.exists(file.path(dir, paste0("out_", sites, ".rds"))))) break
    if (Sys.time() > dl) stop("sites did not finish"); Sys.sleep(0.05) }
  outs <- lapply(sites, function(s) readRDS(file.path(dir, paste0("out_", s, ".rds"))))
  names(outs) <- sites
  pf <- pooledFit(P, a)
  cat(sprintf("\n--- P = %d, alpha = %.2f ---\n", P, a))
  cat(sprintf("  aggregator rounds (excl. completion) : %d\n", nR - 1L))
  for (s in sites) cat(sprintf("  site %s: n=%-4d passes=%-4d rounds=%-8d flag=%s\n",
      s, outs[[s]]$n, outs[[s]]$iter, outs[[s]]$rounds, outs[[s]]$flag))
  bs <- lapply(outs, `[[`, "beta")
  cat(sprintf("  all sites returned identical coefficients : %s\n",
      all(sapply(bs[-1], function(b) identical(b, bs[[1]])))))
  cat(sprintf("  federated vs POOLED: max|diff| = %.3e   relerr = %.3e   support identical = %s\n",
      max(abs(bs[[1]]-pf$beta)), sqrt(sum((bs[[1]]-pf$beta)^2))/sqrt(sum(pf$beta^2)),
      identical(which(bs[[1]]!=0), which(pf$beta!=0))))
  cat(sprintf("  pooled objective: federated %.12f  vs  pooled %.12f   gap %.3e\n",
      obj(bs[[1]]), obj(pf$beta), obj(bs[[1]])-obj(pf$beta)))
  cat(sprintf("  nnz %d vs %d ; passes %d vs %d\n",
      sum(bs[[1]]!=0), sum(pf$beta!=0), outs[[1]]$iter, pf$iter))
}
