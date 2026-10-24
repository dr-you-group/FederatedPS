## Helpers for the proximal block CCD tests.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
suppressPackageStartupMessages(library(Matrix))
dir.create(file.path(FP_OUT, "validation"), recursive = TRUE, showWarnings = FALSE)
useCyclops <- function(which = c("patched","stock")) {
  which <- match.arg(which)
  patched <- strsplit(FP_LIB, .Platform$path.sep, fixed = TRUE)[[1]]
  lp <- if (which == "patched") unique(c(patched, .libPaths())) else setdiff(.libPaths(), patched)
  .libPaths(lp)
  suppressPackageStartupMessages(library(Cyclops))
  invisible(which)
}

## Identity aggregator for one logical site that records every exchange (sizes and timings).
## Since the protocol sums local sums, this gives the same statistics as a K-site run.
makeRecorder <- function(keepTrace = TRUE) {
  e <- new.env()
  e$n <- 0L; e$nLoopCoord <- 0L; e$nConv <- 0L
  e$bytesUp <- 0; e$bytesDown <- 0; e$doubles <- 0
  e$tAgg <- 0; e$trace <- list()
  e$fn <- function(coordinate, statistics) {
    t0 <- Sys.time()
    e$n <- e$n + 1L
    if (coordinate == 0L) e$nConv <- e$nConv + 1L else e$nLoopCoord <- e$nLoopCoord + 1L
    e$doubles <- e$doubles + length(statistics)
    if (keepTrace) e$trace[[e$n]] <- list(c = coordinate, s = statistics)
    e$tAgg <- e$tAgg + as.numeric(difftime(Sys.time(), t0, units = "secs"))
    statistics
  }
  e
}

## pda wire size: jsonlite with digits = 17, as R/Pda.R uses.
BYTES_PER_DOUBLE <- 20.5; MS_PER_ROUND <- 6.7e-3
wireBytes <- function(rec, K) {
  ## each of K sites uploads its packet and downloads the aggregate
  2 * K * rec$doubles * BYTES_PER_DOUBLE
}

lambdaOf <- function(v) sqrt(2 / v)

pooledStats <- function(beta, X, y, lambda) {
  eta <- as.vector(X %*% beta); p <- 1/(1+exp(-eta))
  nll <- sum(log1p(exp(eta)) - y*eta)
  g   <- as.vector(crossprod(X, p - y))
  nz  <- which(beta != 0); nz <- nz[nz != 1L]; z <- setdiff(seq_along(beta)[-1L], nz)
  kkt <- max(abs(g[1L]),
             if (length(nz)) max(abs(g[nz] + lambda*sign(beta[nz]))) else 0,
             if (length(z))  max(pmax(0, abs(g[z]) - lambda)) else 0)
  list(obj = nll + lambda*sum(abs(beta[-1L])), gradNorm = sqrt(sum(g^2)),
       kkt = kkt, nnz = sum(beta != 0), ps = p)
}

buildCyclops <- function(X, y) {
  sx <- Matrix::Matrix(X[, -1, drop = FALSE], sparse = TRUE)
  sx <- as(sx, "CsparseMatrix"); colnames(sx) <- paste0("v", seq_len(ncol(sx)))
  cd <- Cyclops::createCyclopsData(treatment ~ 1, data = data.frame(treatment = y),
                                   sx = sx, modelType = "lr", floatingPoint = 64)
  cd$coefficientNames <- c("(Intercept)", colnames(sx))
  cd
}

runFit <- function(X, y, P = 1L, alpha = 1, variance = 1, tol = 1e-6,
                   maxIterations = 1000L, aggregate = TRUE, keepTrace = FALSE) {
  cd  <- buildCyclops(X, y)
  rec <- if (aggregate) makeRecorder(keepTrace) else NULL
  hasBlock <- "blockSize" %in% names(formals(Cyclops::createControl))
  ctl <- if (aggregate && hasBlock)
    Cyclops::createControl(convergenceType = "lange", tolerance = tol, seed = 1L,
                           noiseLevel = "silent", maxIterations = maxIterations,
                           aggregate = rec$fn, blockSize = P, alpha = alpha)
  else if (aggregate) {
    stopifnot(P == 1L, alpha == 1)
    Cyclops::createControl(convergenceType = "lange", tolerance = tol, seed = 1L,
                           noiseLevel = "silent", maxIterations = maxIterations,
                           aggregate = rec$fn)
  } else
    Cyclops::createControl(convergenceType = "lange", tolerance = tol, seed = 1L,
                           noiseLevel = "silent", maxIterations = maxIterations)
  t0 <- Sys.time()
  fit <- Cyclops::fitCyclopsModel(cd,
    prior = Cyclops::createPrior("laplace", variance = variance,
                                 exclude = "(Intercept)", useCrossValidation = FALSE),
    control = ctl, startingCoefficients = rep(0, ncol(X)))
  wall <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  list(beta = unname(stats::coef(fit)), flag = fit$return_flag,
       iterations = fit$iterations, rec = rec, wall = wall)
}
