## Check that the P = 1 path is unchanged by the block patch (compares against a stored fit).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
LIB <- commandArgs(trailingOnly=TRUE)[1]
.libPaths(c(LIB, .libPaths()))
suppressPackageStartupMessages({library(Matrix); library(Cyclops, lib.loc=LIB)})
set.seed(11); n <- 400L; d <- 25L
Xd <- matrix(rbinom(n*d,1,0.35), n, d)
y  <- rbinom(n,1,1/(1+exp(-(-0.3 + Xd %*% c(1.2,-0.9,0.7,rep(0,d-3))))))
X  <- cbind(1, Xd)
sx <- as(Matrix(X[,-1,drop=FALSE], sparse=TRUE), "CsparseMatrix"); colnames(sx) <- paste0("v",1:d)
cd <- createCyclopsData(treatment~1, data=data.frame(treatment=y), sx=sx, modelType="lr", floatingPoint=64)
cd$coefficientNames <- c("(Intercept)", colnames(sx))
tr <- list(); n0 <- 0L
cb <- function(coordinate, statistics){ n0 <<- n0+1L; tr[[n0]] <<- c(coordinate, statistics); statistics }
fit <- fitCyclopsModel(cd, prior=createPrior("laplace",variance=1,exclude="(Intercept)",useCrossValidation=FALSE),
  control=createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
                        aggregate=cb, blockSize=1L, alpha=1), startingCoefficients=rep(0,d+1))
cat(sprintf("%s: iter=%d nnz=%d exchanges=%d  trace-hash=%s\n", LIB, fit$iterations,
    sum(coef(fit)!=0), n0, substr(digest::digest(unlist(tr)),1,16)))
saveRDS(list(beta=unname(coef(fit)), iter=fit$iterations, n=n0, tr=unlist(tr)),
        sprintf(file.path(FP_OUT, "phases/vf_%s.rds"), gsub("/","",LIB)))
