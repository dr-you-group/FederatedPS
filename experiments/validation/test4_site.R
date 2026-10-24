source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
a <- commandArgs(trailingOnly = TRUE)
site <- a[1]; dir <- a[2]; P <- as.integer(a[3]); alpha <- as.numeric(a[4])

suppressPackageStartupMessages({library(Cyclops); library(Matrix)})
source(file.path(FP_EXP, "validation/fed3_common.R"))
D <- readRDS(file.path(dir, "data.rds")); X <- D$X[[site]]; y <- D$y[[site]]
round <- 0L
exch <- function(coordinate, statistics) {
  v <- as.vector(statistics); attr(v, "coordinate") <- as.integer(coordinate)
  put(v, paste0("r", round, "_", site), dir)
  res <- get1(paste0("r", round, "_total"), dir)
  round <<- round + 1L
  as.vector(res)
}
sx <- as(Matrix(X[,-1,drop=FALSE], sparse=TRUE), "CsparseMatrix")
colnames(sx) <- paste0("v", seq_len(ncol(sx)))
cd <- createCyclopsData(treatment~1, data=data.frame(treatment=y), sx=sx,
                        modelType="lr", floatingPoint=64)
cd$coefficientNames <- c("(Intercept)", colnames(sx))
fit <- fitCyclopsModel(cd,
  prior = createPrior("laplace", variance=1, exclude="(Intercept)", useCrossValidation=FALSE),
  control = createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
                          aggregate=exch, blockSize=P, alpha=alpha),
  startingCoefficients = rep(0, ncol(X)))
v <- 0; attr(v, "coordinate") <- -99L                       # signal completion
put(v, paste0("r", round, "_", site), dir); get1(paste0("r", round, "_total"), dir)
saveRDS(list(beta=unname(stats::coef(fit)), iter=fit$iterations, flag=fit$return_flag,
             rounds=round, n=nrow(X)), file.path(dir, paste0("out_", site, ".rds")))
