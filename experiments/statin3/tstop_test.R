source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))

suppressPackageStartupMessages({library(Matrix); library(Cyclops)})
set.seed(3); n <- 800L; d <- 40L
Xd <- matrix(rbinom(n*d,1,0.35), n, d)
y <- rbinom(n,1,1/(1+exp(-(-0.3 + Xd %*% c(1.1,-0.8,0.6, rep(0,d-3))))))
sx <- as(Matrix(Xd, sparse=TRUE),"CsparseMatrix"); colnames(sx) <- paste0("v",1:d)
cd <- createCyclopsData(treatment~1, data=data.frame(treatment=y), sx=sx, modelType="lr", floatingPoint=64)
cd$coefficientNames <- c("(Intercept)", colnames(sx))
bg <- rnorm(d+1, 0, 0.3)

## Stop after T local sweeps by returning the previous objective at coordinate 0 (delta = 0).
localFit <- function(mu, T, start) {
  st <- new.env(); st$pass <- 0L; st$last <- NULL; st$coordCalls <- 0L
  cb <- function(coordinate, statistics) {
    if (coordinate == 0L) {
      st$pass <- st$pass + 1L
      if (st$pass > T && !is.null(st$last)) return(st$last)   # forced convergence
      st$last <- statistics; return(statistics)
    }
    st$coordCalls <- st$coordCalls + 1L
    s <- statistics; s[1] <- s[1] + mu*(s[3] - bg[coordinate]); s[2] <- s[2] + mu; s
  }
  f <- fitCyclopsModel(cd, prior=createPrior("laplace", variance=1, exclude="(Intercept)",
        useCrossValidation=FALSE),
    control=createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
      tolerance=1e-8, maxIterations=1000L, aggregate=cb), startingCoefficients=start)
  list(beta=unname(coef(f)), it=f$iterations, flag=f$return_flag,
       sweeps=st$pass, coordCalls=st$coordCalls)
}
cat("requested T -> local sweeps / Cyclops iterations / coordinate calls / flag\n")
for (T in c(1L,2L,3L,5L,10L,50L)) {
  r <- localFit(1, T, rep(0, d+1))
  cat(sprintf("  T=%-3d -> sweeps=%-3d it=%-3d coordCalls=%-5d flag=%s  nnz=%d\n",
      T, r$sweeps, r$it, r$coordCalls, r$flag, sum(r$beta!=0)))
}
cat("\ncoordinate calls vs T*(d+1), d+1 = 41:\n")
for (T in c(1L,3L,10L)) { r <- localFit(1, T, rep(0,d+1))
  cat(sprintf("  T=%-3d coordCalls=%-5d expected=%-5d equal=%s\n", T, r$coordCalls, T*41, r$coordCalls==T*41)) }
cat("\nwarm start: ten runs with T=1 vs one run with T=10\n")
b <- rep(0,d+1); for (i in 1:10) b <- localFit(1, 1L, b)$beta
b10 <- localFit(1, 10L, rep(0,d+1))$beta
cat(sprintf("  max|diff| = %.3e\n", max(abs(b-b10))))
