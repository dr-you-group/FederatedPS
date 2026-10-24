fp_verify_results <- function(config) {
    success_path <- file.path(config$output, "SUCCESS.txt")
    if (file.exists(success_path)) unlink(success_path)
    coefficients <- readRDS(file.path(config$output, "aggregator", "result.rds"))
    stopifnot(length(coefficients) > 1L, all(is.finite(coefficients)))
    for (site in config$sites) {
        result <- readRDS(file.path(config$output, site, "result.rds"))
        if (config$mode == "Database") {
            stopifnot(is.data.frame(result), "propensityScore" %in% names(result), nrow(result) > 0L)
            stopifnot(isTRUE(all.equal(attr(result, "metaData")$psModelCoef,
                                      coefficients, tolerance = 1e-10)))
            scores <- result$propensityScore
        } else {
            stopifnot(isTRUE(all.equal(result$coefficients, coefficients, tolerance = 1e-10)),
                      length(result$propensityScore) == length(result$rowIds))
            scores <- result$propensityScore
        }
        stopifnot(length(scores) > 0L, all(is.finite(scores)), all(scores >= 0 & scores <= 1))
    }
    if (config$mode == "Synthetic") {
        # Only synthetic rows are combined for this numerical reference check.
        inputs <- lapply(config$sites, function(site)
            readRDS(file.path(config$output, site, "synthetic-input.rds")))
        x <- do.call(rbind, lapply(inputs, `[[`, "x"))
        y <- unlist(lapply(inputs, `[[`, "treatment"))
        x <- x[, names(coefficients)[-1], drop = FALSE]
        data <- Cyclops::createCyclopsData(y ~ 1, data = data.frame(y = y), sx = x,
                                          modelType = "lr", floatingPoint = 64)
        data$coefficientNames <- c("(Intercept)", colnames(x))
        fit <- Cyclops::fitCyclopsModel(data,
            prior = Cyclops::createPrior("laplace", variance = 1, exclude = "(Intercept)", useCrossValidation = FALSE),
            control = Cyclops::createControl(convergenceType = "lange", tolerance = 1e-10,
                maxIterations = 5000L, threads = 1L, seed = 1L, noiseLevel = "silent"),
            startingCoefficients = rep(0, ncol(x) + 1L))
        stopifnot(fit$return_flag == "SUCCESS")
        max_delta <- max(abs(coefficients - stats::coef(fit)[names(coefficients)]))
        cat("Synthetic max coefficient difference from pooled CCD:", max_delta, "\n")
        if (!is.finite(max_delta) || max_delta > 0.01)
            stop("Synthetic numerical check failed; inspect the control settings and per-role logs")
    }
    writeLines(c("PASS", paste("Run:", config$runId), paste("Mode:", config$mode)),
               success_path)
    cat("PASS: every role produced valid results\n")
}

if (sys.nframe() == 0L) {
    args <- commandArgs(trailingOnly = TRUE)
    stopifnot(length(args) == 1L)
    fp_verify_results(jsonlite::fromJSON(args[1]))
}
