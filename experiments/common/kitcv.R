## Laplace logistic fit with the prior variance chosen by cross-validation.
## Follows the CohortMethod::createPs defaults except cvRepetitions = 1 and fold = 5.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
fitCV <- function(Xs, ys, variance = NULL) {
  pres <- which(colSums(Xs != 0) > 0)
  if (!length(pres) || length(unique(ys)) < 2) return(NULL)
  sx <- Xs[, pres, drop = FALSE]; colnames(sx) <- paste0("v", seq_along(pres))
  cd <- createCyclopsData(treatment ~ 1, data = data.frame(treatment = ys), sx = sx, modelType = "lr", floatingPoint = 64)
  prior <- if (is.null(variance)) createPrior("laplace", exclude = "(Intercept)", useCrossValidation = TRUE)
           else createPrior("laplace", variance = variance, exclude = "(Intercept)", useCrossValidation = FALSE)
  fit <- try(suppressWarnings(fitCyclopsModel(cd, prior = prior,
    control = createControl(cvType = "auto", fold = 5L, cvRepetitions = 1L, startingVariance = 0.01,
      seed = 1L, noiseLevel = "silent", tolerance = 2e-7, threads = 1L))), silent = TRUE)
  if (inherits(fit, "try-error") || fit$return_flag != "SUCCESS") return(NULL)
  b <- unname(coef(fit)); if (!all(is.finite(b))) return(NULL)
  list(b0 = b[1], bj = b[-1], idx = pres, variance = fit$variance[1]) }
