## Federated block run vs a single-process run with the same P and alpha.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
a <- commandArgs(trailingOnly=TRUE); scen<-a[1]; run<-a[2]; sites<-a[-(1:2)]

suppressPackageStartupMessages({library(Matrix); library(Cyclops)})
lam <- sqrt(2)
res <- lapply(sites, function(s) readRDS(sprintf(file.path(FP_OUT, "fedruns/%s/%s.rds"), run, s)))
agg <- readRDS(sprintf(file.path(FP_OUT, "fedruns/%s/agg.rds"), run))
D <- lapply(sites, function(s) readRDS(sprintf(file.path(FP_OUT, "sitedata/%s/%s.rds"), scen, s)))
feat <- as.character(sort(unique(as.numeric(unlist(lapply(D, function(d) colnames(d$x)))))))
expand <- function(d){ j<-match(colnames(d$x),feat); t<-Matrix::summary(as(d$x,"TsparseMatrix"))
  sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(nrow(d$x), length(feat))) }
X <- do.call(rbind, lapply(D, expand)); y <- unlist(lapply(D,`[[`,"treatment"))
keep <- res[[1]]$keep
X <- as(cbind(Matrix(1,nrow(X),1,sparse=TRUE), X)[, c(TRUE, keep), drop=FALSE], "CsparseMatrix")
P <- res[[1]]$P; al <- res[[1]]$alpha
sx <- X[,-1,drop=FALSE]; colnames(sx) <- paste0("v", seq_len(ncol(sx)))
cd <- createCyclopsData(treatment~1, data=data.frame(treatment=y), sx=sx, modelType="lr", floatingPoint=64)
cd$coefficientNames <- c("(Intercept)", colnames(sx))
n <- 0L; f <- function(coordinate, statistics){ n <<- n + 1L; statistics }
fit <- suppressWarnings(fitCyclopsModel(cd, prior=createPrior("laplace",variance=1,
        exclude="(Intercept)", useCrossValidation=FALSE),
      control=createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
              tolerance=1e-6, maxIterations=1000L, aggregate=f, blockSize=P, alpha=al),
      startingCoefficients=rep(0, ncol(X))))
b1 <- unname(stats::coef(fit)); bf <- unname(agg$coefficients)
cat(sprintf("same-config single process : passes=%d rounds=%d nnz=%d\n", fit$iterations, n, sum(b1!=0)))
cat(sprintf("K=%d federation             : passes=%d rounds=%d nnz=%d\n",
    length(sites), res[[1]]$iterations, res[[1]]$loopRounds, sum(bf!=0)))
cat(sprintf("  max|diff| = %.3e   relerr = %.3e   support identical = %s   rounds equal = %s\n",
    max(abs(bf-b1)), sqrt(sum((bf-b1)^2))/max(1e-300,sqrt(sum(b1^2))),
    identical(which(bf!=0), which(b1!=0)), n == res[[1]]$loopRounds))

## ---- p_k = n_k / N weighted averaging, for comparison ----
nk <- sapply(D, function(d) nrow(d$x)); pk <- nk/sum(nk)
cat(sprintf("\nsite sizes %s  ->  p_k = %s\n", paste(nk, collapse="/"),
            paste(sprintf("%.3f", pk), collapse="/")))
g <- numeric(ncol(X)); gw <- numeric(ncol(X)); off <- 0L
p <- 1/(1+exp(-as.vector(X %*% bf)))
for (k in seq_along(D)) { idx <- (off+1):(off+nk[k]); off <- off + nk[k]
  gk <- as.vector(crossprod(X[idx,,drop=FALSE], p[idx]-y[idx]))
  g  <- g  + gk                       # sum of local sums
  gw <- gw + pk[k] * (gk/nk[k])       # p_k-weighted mean of local averages
}
cat(sprintf("  unweighted sum_k local_sum_k : |g|_2 = %.6f\n", sqrt(sum(g^2))))
cat(sprintf("  sum_k p_k * local_average_k  : |g|_2 = %.6f   ratio = %.1f\n",
    sqrt(sum(gw^2)), sqrt(sum(g^2))/sqrt(sum(gw^2))))
cat(sprintf("  the two differ by a factor of N = %d : %s\n", sum(nk),
    isTRUE(all.equal(g, gw*sum(nk), tolerance=1e-9))))
cat("  => the implementation optimises the POOLED likelihood; no p_k weighting present.\n")
