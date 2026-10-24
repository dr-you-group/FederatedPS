## Data-shared lasso (Gross & Tibshirani 2016), fitted centrally on the equivalent augmented design.
## Site k: logit p = a_k + x'(beta + delta_k), penalty lambda * (|beta|_1 + r * sum_k |delta_k|_1).
## With columns [X, X * 1{site = k} / r] a single Laplace prior gives the same problem (delta_k = delta'_k / r).
## r is chosen by the Cyclops cross-validated log-likelihood (fixed seed, so the folds are shared across r).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
augDSL <- function(X, site, K, r) {
  blocks <- lapply(1:K, function(k) { w <- as.numeric(site == k) / r; Diagonal(x = w) %*% X })
  S <- sparseMatrix(i = which(site > 1), j = site[site > 1] - 1L, x = 1, dims = c(nrow(X), max(1L, K - 1L)))
  cbind(S, X, do.call(cbind, blocks)) }
fitDSL1 <- function(X, y, site, K, r) {
  A <- augDSL(X, site, K, r); pres <- which(colSums(A != 0) > 0)
  nS <- K - 1L; keepS <- pres[pres <= nS]
  sx <- A[, pres, drop = FALSE]; nm <- paste0("v", seq_along(pres)); nm[pres <= nS] <- paste0("s", seq_along(keepS)); colnames(sx) <- nm
  cd <- createCyclopsData(treatment ~ 1, data = data.frame(treatment = y), sx = sx, modelType = "lr", floatingPoint = 64)
  cd$coefficientNames <- c("(Intercept)", nm)
  fit <- try(suppressWarnings(fitCyclopsModel(cd,
    prior = createPrior("laplace", exclude = c("(Intercept)", nm[pres <= nS]), useCrossValidation = TRUE),
    control = createControl(cvType = "auto", fold = 5L, cvRepetitions = 1L, startingVariance = 0.01,
      seed = 1L, noiseLevel = "silent", tolerance = 2e-7, threads = 1L))), silent = TRUE)
  if (inherits(fit, "try-error") || fit$return_flag != "SUCCESS") return(NULL)
  b <- unname(coef(fit)); if (!all(is.finite(b))) return(NULL)
  list(b0 = b[1], b = b[-1], pres = pres, r = r, K = K, variance = fit$variance[1],
       cvScore = as.numeric(strsplit(fit$cross_validation, " ")[[1]][1])) }
## Model with the best CV score over the r grid.
fitDSL <- function(X, y, site, K, rgrid = c(0.25, 0.5, 1, 2, 4)) {
  fs <- lapply(rgrid, function(r) fitDSL1(X, y, site, K, r)); fs <- Filter(Negate(is.null), fs)
  if (!length(fs)) return(NULL); sc <- sapply(fs, `[[`, "cvScore")
  m <- fs[[which.max(sc)]]; m$grid <- setNames(sc, sapply(fs, `[[`, "r")); m }
predDSL <- function(m, X, k) { if (is.null(m)) return(rep(NA_real_, nrow(X)))
  A <- augDSL(X, rep(k, nrow(X)), m$K, m$r)[, m$pres, drop = FALSE]
  1 / (1 + exp(-(m$b0 + as.vector(A %*% m$b)))) }
