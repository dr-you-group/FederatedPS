## Proximal anchor through the aggregate callback.
## Local objective: sum_i loss_i + lambda |b|_1 + mu/2 ||b - bg||^2
## Coordinate update: (g, h) -> (g + mu (b_j - bg_j), h + mu)
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))

suppressPackageStartupMessages({library(Matrix); library(Cyclops)})
set.seed(3); n <- 800L; d <- 40L
Xd <- matrix(rbinom(n*d,1,0.35), n, d)
y <- rbinom(n,1,1/(1+exp(-(-0.3 + Xd %*% c(1.1,-0.8,0.6, rep(0,d-3))))))
X <- cbind(1, Xd); lam <- sqrt(2)
sx <- as(Matrix(Xd, sparse=TRUE),"CsparseMatrix"); colnames(sx) <- paste0("v",1:d)
cd <- createCyclopsData(treatment~1, data=data.frame(treatment=y), sx=sx, modelType="lr", floatingPoint=64)
cd$coefficientNames <- c("(Intercept)", colnames(sx))
bg <- rnorm(d+1, 0, 0.3)                      # random anchor
MU <- 5

fitAnchor <- function(mu, maxIt=1000L) {
  cb <- function(coordinate, statistics) {
    if (coordinate == 0L) return(statistics)
    s <- statistics                            # (g, h, beta, bound)
    s[1] <- s[1] + mu * (s[3] - bg[coordinate])
    s[2] <- s[2] + mu
    s }
  f <- fitCyclopsModel(cd, prior=createPrior("laplace", variance=1, exclude="(Intercept)",
        useCrossValidation=FALSE),
    control=createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
      tolerance=1e-8, maxIterations=maxIt, aggregate=cb), startingCoefficients=rep(0,d+1))
  list(beta=unname(coef(f)), it=f$iterations, flag=f$return_flag) }

obj <- function(b, mu) { e <- as.vector(X %*% b)
  sum(log1p(exp(e)) - y*e) + lam*sum(abs(b[-1])) + mu/2*sum((b-bg)^2) }
grad <- function(b, mu) { p <- 1/(1+exp(-as.vector(X %*% b)))
  as.vector(crossprod(X, p-y)) + mu*(b-bg) }
kkt <- function(b, mu) { g <- grad(b, mu); nz <- which(b!=0); nz <- nz[nz!=1]; z <- setdiff(2:(d+1), nz)
  max(abs(g[1]), if(length(nz)) max(abs(g[nz]+lam*sign(b[nz]))) else 0,
      if(length(z)) max(pmax(0, abs(g[z])-lam)) else 0) }
for (mu in c(0, MU)) {
  r <- fitAnchor(mu)
  cat(sprintf("mu=%-3g flag=%s it=%-3d  obj=%.6f  KKT(anchored)=%.3e  nnz=%d  ||b-bg||=%.4f\n",
      mu, r$flag, r$it, obj(r$beta, mu), kkt(r$beta, mu), sum(r$beta!=0), sqrt(sum((r$beta-bg)^2))))
}
cat("\ndistance to bg as mu grows:\n")
for (mu in c(0, 1, 10, 100, 1000)) { r <- fitAnchor(mu)
  cat(sprintf("  mu=%-5g ||b-bg||=%.5f  nnz=%d\n", mu, sqrt(sum((r$beta-bg)^2)), sum(r$beta!=0))) }
cat("\nmaxIterations as the number of local sweeps T:\n")
for (T in c(1,2,5,20)) { r <- fitAnchor(1, maxIt=as.integer(T))
  cat(sprintf("  T=%-3d requested -> %d passes (flag=%s)\n", T, r$it, r$flag)) }
