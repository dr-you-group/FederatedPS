## Trust region with and without the 1/alpha rescaling, on MIMIC (pass the library path).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
lib <- commandArgs(trailingOnly = TRUE)[1]
.libPaths(c(lib, .libPaths()))
suppressPackageStartupMessages({library(Cyclops, lib.loc=lib); library(Matrix)})
dd <- readRDS(file.path(FP_DATA, "statin/mimic/design.rds"))
rows <- sort(dd$rowId); feat <- dd$covariateIds
i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat); ok <- !is.na(i)&!is.na(j)
Xs <- sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok], dims=c(length(rows),length(feat)))
Xs <- as(cbind(Matrix(1,length(rows),1,sparse=TRUE), Xs), "CsparseMatrix")
y <- dd$treatment[match(rows, dd$rowId)]
set.seed(20260921); grp <- sample(rep(1:2, length.out=nrow(Xs)))
present <- Reduce(`|`, lapply(1:2, function(k) colSums(Xs[grp==k,,drop=FALSE]!=0)>0)); present[1] <- TRUE
X <- Xs[, present, drop=FALSE]; d <- ncol(X); lam <- sqrt(2)
sx <- X[,-1,drop=FALSE]; colnames(sx) <- paste0("v", seq_len(ncol(sx)))
cd <- createCyclopsData(treatment~1, data=data.frame(treatment=y), sx=sx, modelType="lr", floatingPoint=64)
cd$coefficientNames <- c("(Intercept)", colnames(sx))
obj <- function(b){e<-as.vector(X%*%b); sum(log1p(exp(e))-y*e)+lam*sum(abs(b[-1]))}
cat("library:", lib, "\n")
for (cfg in list(c(1,1), c(20,0.52), c(20,0.05), c(100,0.17))) {
  P <- as.integer(cfg[1]); a <- cfg[2]; n <- 0L
  f <- function(coordinate, statistics){ n <<- n + 1L; statistics }
  fit <- suppressWarnings(fitCyclopsModel(cd,
    prior=createPrior("laplace",variance=1,exclude="(Intercept)",useCrossValidation=FALSE),
    control=createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
            tolerance=1e-6, maxIterations=1000L, aggregate=f, blockSize=P, alpha=a),
    startingCoefficients=rep(0,d)))
  b <- unname(stats::coef(fit))
  cat(sprintf("  P=%-4d a=%-5.2f passes=%-4d exchanges=%-9s obj=%.6f nnz=%-5d flag=%s\n",
      P, a, fit$iterations, format(n, big.mark=","), obj(b), sum(b!=0), fit$return_flag))
}
