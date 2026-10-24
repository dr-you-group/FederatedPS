## Local computation time for the full problem in one process, same configuration.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))

suppressPackageStartupMessages({library(Matrix); library(Cyclops)})
base <- readRDS(file.path(FP_DATA, "statin/mimic/psModelCoef.rds")); target <- names(base)[-1]
loadD <- function(nm){ dd <- readRDS(sprintf(file.path(FP_DATA, "statin/%s/design.rds"), nm))
  rows <- sort(dd$rowId); feat <- as.character(dd$covariateIds)
  i <- match(dd$cov$rowId, rows); j <- match(as.character(dd$cov$covariateId), feat)
  ok <- !is.na(i)&!is.na(j)
  X <- sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok], dims=c(length(rows), length(feat)))
  jj <- match(feat, target); t <- Matrix::summary(as(X,"TsparseMatrix"))
  list(X=sparseMatrix(i=t$i, j=jj[t$j], x=t$x, dims=c(length(rows), length(target))),
       y=dd$treatment[match(rows, dd$rowId)]) }
M <- loadD("mimic"); S <- loadD("synpuf")
X <- rbind(M$X, S$X); y <- c(M$y, S$y)
colnames(X) <- paste0("v", seq_len(ncol(X)))
cd <- createCyclopsData(treatment~1, data=data.frame(treatment=y), sx=as(X,"CsparseMatrix"),
                        modelType="lr", floatingPoint=64)
cd$coefficientNames <- c("(Intercept)", colnames(X))
for (cfg in list(c(1,1), c(20,0.52))) {
  P <- as.integer(cfg[1]); a <- cfg[2]; n <- 0L
  f <- function(coordinate, statistics){ n <<- n + 1L; statistics }
  t0 <- Sys.time()
  fit <- suppressWarnings(fitCyclopsModel(cd, prior=createPrior("laplace",variance=1,
      exclude="(Intercept)", useCrossValidation=FALSE),
    control=createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
      tolerance=1e-6, maxIterations=1000L, aggregate=f, blockSize=P, alpha=a),
    startingCoefficients=rep(0, ncol(X)+1L)))
  cat(sprintf("single process P=%-3d alpha=%-5.2f : passes=%d rounds=%s  LOCAL COMPUTE %.1f s\n",
      P, a, fit$iterations, format(n, big.mark=","),
      as.numeric(difftime(Sys.time(), t0, units="secs"))))
}
