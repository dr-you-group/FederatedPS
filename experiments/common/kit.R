## Shared helpers: design loading, Cyclops runs, solution metrics, matching and balance.
## runCfg() needs the Cyclops fork pinned in DESCRIPTION (blockSize / alpha in createControl).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))

suppressPackageStartupMessages({library(Matrix); library(Cyclops)
                                library(CohortMethod)})
LAMBDA1 <- sqrt(2)          # Laplace variance 1  ->  lambda_1 = sqrt(2/v)
BYTES_PER_DOUBLE <- 20.5    # jsonlite digits = 17, measured
BYTES_PER_PACKET <- 29      # JSON envelope, measured
R_OVERHEAD <- 3L            # -3 feature union, -1 spec/keep, -2 coefficients

## ---- data ------------------------------------------------------------------
loadDesign <- function(nm) {
  dd <- readRDS(sprintf(file.path(FP_DATA, "statin/%s/design.rds"), nm))
  rows <- sort(dd$rowId); feat <- dd$covariateIds          # numeric, canonical order
  i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat)
  ok <- !is.na(i) & !is.na(j)
  list(X = sparseMatrix(i = i[ok], j = j[ok], x = dd$cov$covariateValue[ok],
                        dims = c(length(rows), length(feat))),
       feat = feat, y = dd$treatment[match(rows, dd$rowId)], rows = rows)
}
## Re-express a design on a common numeric-sorted feature axis, prepend intercept.
onAxis <- function(D, axis) {
  j <- match(D$feat, axis); t <- Matrix::summary(as(D$X, "TsparseMatrix"))
  as(cbind(Matrix(1, nrow(D$X), 1, sparse = TRUE),
           sparseMatrix(i = t$i, j = j[t$j], x = t$x,
                        dims = c(nrow(D$X), length(axis)))), "CsparseMatrix")
}

## ---- one configuration, in process (same updates and round counts as the K-site federation) ----
runCfg <- function(X, y, P = 1L, alpha = 1, tol = 1e-6, maxIterations = 1000L,
                   startingCoefficients = NULL, variance = 1) {
  sx <- X[, -1, drop = FALSE]; colnames(sx) <- paste0("v", seq_len(ncol(sx)))
  cd <- createCyclopsData(treatment ~ 1, data = data.frame(treatment = y), sx = sx,
                          modelType = "lr", floatingPoint = 64)
  cd$coefficientNames <- c("(Intercept)", colnames(sx))
  st <- new.env(); st$n <- 0L; st$conv <- 0L; st$dbl <- 0; st$t <- 0
  cb <- function(coordinate, statistics) {
    st$n <- st$n + 1L; if (coordinate == 0L) st$conv <- st$conv + 1L
    st$dbl <- st$dbl + length(statistics); statistics
  }
  t0 <- Sys.time()
  fit <- suppressWarnings(fitCyclopsModel(cd,
    prior = createPrior("laplace", variance = variance, exclude = "(Intercept)",
                        useCrossValidation = FALSE),
    control = createControl(convergenceType = "lange", seed = 1L, noiseLevel = "silent",
      tolerance = tol, maxIterations = maxIterations, aggregate = cb,
      blockSize = P, alpha = alpha),
    startingCoefficients = if (is.null(startingCoefficients)) rep(0, ncol(X)) else startingCoefficients))
  wall <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  d <- ncol(X); S <- fit$iterations
  list(beta = unname(stats::coef(fit)), flag = fit$return_flag, passes = S, d = d, P = P,
       alpha = alpha, blocksPerPass = ceiling(d / P),
       R_loop_formula = (ceiling(d / P) + 1L) * S, R_loop = st$n,
       convExchanges = st$conv, R_overhead = R_OVERHEAD, R_total = st$n + R_OVERHEAD,
       payloadDoubles = st$dbl, localSeconds = wall,
       diverged = !all(is.finite(unname(stats::coef(fit)))) || fit$return_flag != "SUCCESS")
}
bytesOf <- function(r, K) K * 2 * (r$payloadDoubles * BYTES_PER_DOUBLE +
                                   r$R_loop * BYTES_PER_PACKET)

## ---- solution metrics ------------------------------------------------------
metrics <- function(beta, X, y) {
  eta <- as.vector(X %*% beta); p <- 1 / (1 + exp(-eta))
  g <- as.vector(crossprod(X, p - y))
  nz <- which(beta != 0); nz <- nz[nz != 1L]; z <- setdiff(seq_along(beta)[-1L], nz)
  list(obj = sum(log1p(exp(eta)) - y * eta) + LAMBDA1 * sum(abs(beta[-1L])),
       gradNorm = sqrt(sum(g^2)),
       kkt = max(abs(g[1L]),
                 if (length(nz)) max(abs(g[nz] + LAMBDA1 * sign(beta[nz]))) else 0,
                 if (length(z))  max(pmax(0, abs(g[z]) - LAMBDA1)) else 0),
       nnz = sum(beta != 0), ps = p)
}

## ---- balance ---------------------------------------------------------------
## Covariates are binary indicators, so the SMD uses p (1 - p) as the variance.
smdStats <- function(Z, y, idx = NULL) {
  if (!is.null(idx)) { Z <- Z[idx, , drop = FALSE]; y <- y[idx] }
  t1 <- as.numeric(y == 1); t0 <- as.numeric(y == 0)
  n1 <- sum(t1); n0 <- sum(t0)
  p1 <- as.vector(crossprod(Z, t1)) / n1
  p0 <- as.vector(crossprod(Z, t0)) / n0
  den <- sqrt((p1 * (1 - p1) + p0 * (1 - p0)) / 2)
  keep <- den > 1e-8
  d <- abs(p1 - p0)[keep] / den[keep]
  list(smd = d, which = which(keep), n1 = n1, n0 = n0,
       summary = c(mean = mean(d), median = median(d), p90 = unname(quantile(d, 0.9)),
                   max = max(d), n_gt_0.1 = sum(d > 0.1), n_gt_0.2 = sum(d > 0.2),
                   nCov = length(d)))
}
matchPs <- function(ps, y, rowId = seq_along(y), caliper = 0.2) {
  pop <- data.frame(rowId = rowId, treatment = y, propensityScore = ps)
  m <- CohortMethod::matchOnPs(pop, matchOnPsArgs = CohortMethod::createMatchOnPsArgs(
         caliper = caliper, caliperScale = "standardized logit", maxRatio = 1))
  list(idx = match(m$rowId, rowId), pairs = sum(m$treatment == 1),
       unmatchedTreated = sum(y == 1) - sum(m$treatment == 1),
       unmatchedControl = sum(y == 0) - sum(m$treatment == 0))
}
