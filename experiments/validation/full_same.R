## Full scale: K = 3 federation vs a single process with the same P and alpha.
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
X <- rbind(M$X, S$X); y <- c(M$y, S$y); colnames(X) <- paste0("v", seq_len(ncol(X)))
cd <- createCyclopsData(treatment~1, data=data.frame(treatment=y), sx=as(X,"CsparseMatrix"),
                        modelType="lr", floatingPoint=64)
cd$coefficientNames <- c("(Intercept)", colnames(X))
n <- 0L; f <- function(coordinate, statistics){ n <<- n + 1L; statistics }
fit <- suppressWarnings(fitCyclopsModel(cd, prior=createPrior("laplace",variance=1,
    exclude="(Intercept)", useCrossValidation=FALSE),
  control=createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
    tolerance=1e-6, maxIterations=1000L, aggregate=f, blockSize=20L, alpha=0.52),
  startingCoefficients=rep(0, ncol(X)+1L)))
b1 <- unname(stats::coef(fit))
bf <- readRDS(file.path(FP_OUT, "fedruns/fullP20/agg.rds"))$coefficients
bf <- unname(bf[names(base)])
cat(sprintf("single process : passes=%d rounds=%d nnz=%d\n", fit$iterations, n, sum(b1!=0)))
cat(sprintf("K=3 federation : passes=45 rounds=90901 nnz=%d\n", sum(bf!=0)))
cat(sprintf("  max|diff| = %.3e   relerr = %.3e   support identical = %s   rounds equal = %s\n",
    max(abs(bf-b1)), sqrt(sum((bf-b1)^2))/sqrt(sum(b1^2)),
    identical(which(bf!=0), which(b1!=0)), n == 90901L))
