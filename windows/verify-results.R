fp_verify_results <- function(config) {
    success_path <- file.path(config$output, "SUCCESS.txt")
    if (file.exists(success_path)) unlink(success_path)
    coefficients <- readRDS(file.path(config$output, "aggregator", "result.rds"))
    stopifnot(length(coefficients) > 1L, all(is.finite(coefficients)))
    seen_persons <- character()
    for (site in config$sites) {
        result <- readRDS(file.path(config$output, site, "result.rds"))
        if (config$mode %in% c("Database", "SyntheticCDM")) {
            stopifnot(is.data.frame(result), "propensityScore" %in% names(result), nrow(result) > 0L)
            stopifnot(isTRUE(all.equal(attr(result, "metaData")$psModelCoef,
                                      coefficients, tolerance = 1e-10)))
            scores <- result$propensityScore
            if (identical(config$dataset, "YUHS")) {
                stopifnot(identical(as.numeric(attr(result, "metaData")$careSiteId), as.numeric(config$careSites[[site]])),
                          "personId" %in% names(result), !anyNA(result$personId), !anyDuplicated(result$personId))
                ids <- as.character(result$personId)
                if (any(ids %in% seen_persons)) stop("Patient overlap across YUHS institutions; SUCCESS was not written")
                seen_persons <- c(seen_persons, ids)
                if (config$mode == "SyntheticCDM") {
                    stopifnot(isTRUE(attr(result, "metaData")$synthetic))
                    input <- readRDS(file.path(config$output, site, "synthetic-cdm-input.rds"))
                    stopifnot(isTRUE(input$synthetic), nrow(result) == 120L,
                        setequal(result$personId, as.character(input$cohorts$personId)),
                        setequal(result$treatment, c(0, 1)))
                    row <- match(result$rowId, input$cohorts$rowId)
                    stopifnot(!anyNA(row), !anyDuplicated(row),
                        identical(as.character(result$personId), as.character(input$cohorts$personId[row])),
                        all(result$treatment == input$cohorts$treatment[row]))
                    f <- input$covariates
                    eta <- rep(unname(coefficients[1]), nrow(result))
                    contribution <- f$covariateValue * coefficients[match(as.character(f$covariateId), names(coefficients))]
                    contribution[is.na(contribution)] <- 0 # globally absent/zero columns
                    summed <- tapply(contribution, f$rowId, sum)
                    eta <- eta + summed[as.character(result$rowId)]
                    stopifnot(all(is.finite(eta)), max(abs(stats::plogis(eta) - scores)) < 1e-8)
                }
            }
        } else {
            stopifnot(isTRUE(all.equal(result$coefficients, coefficients, tolerance = 1e-10)),
                      length(result$propensityScore) == length(result$rowIds))
            scores <- result$propensityScore
        }
        stopifnot(length(scores) > 0L, all(is.finite(scores)), all(scores >= 0 & scores <= 1))
    }
    if (config$mode %in% c("Synthetic", "SyntheticCDM")) {
        # Only synthetic rows are combined for this numerical reference check.
        inputs <- lapply(config$sites, function(site) {
            if (config$mode == "Synthetic")
                return(readRDS(file.path(config$output, site, "synthetic-input.rds")))
            input <- readRDS(file.path(config$output, site, "synthetic-cdm-input.rds"))
            stopifnot(isTRUE(input$synthetic))
            f <- input$covariates
            features <- names(coefficients)[-1]
            j <- match(as.character(f$covariateId), features)
            take <- which(!is.na(j))
            list(x = Matrix::sparseMatrix(i = match(f$rowId[take], input$cohorts$rowId), j = j[take],
                x = f$covariateValue[take], dims = c(nrow(input$cohorts), length(features)),
                dimnames = list(NULL, features)), treatment = input$cohorts$treatment)
        })
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
        pooled <- stats::coef(fit)[names(coefficients)]
        if (config$mode == "SyntheticCDM") {
            # Complete gender/age indicators can have nonunique coefficients;
            # compare predictions for the identical invented rows instead.
            ps <- function(b) stats::plogis(as.numeric(b[1] + x %*% b[-1]))
            max_delta <- max(abs(ps(coefficients) - ps(pooled)))
            cat("Synthetic CDM max PS difference from pooled CCD:", max_delta, "\n")
        } else {
            max_delta <- max(abs(coefficients - pooled))
            cat("Synthetic max coefficient difference from pooled CCD:", max_delta, "\n")
        }
        if (!is.finite(max_delta) || max_delta > 0.01)
            stop("Synthetic numerical check failed; inspect the control settings and per-role logs")
    }
    writeLines(c("PASS", paste("Run:", config$runId), paste("Mode:", config$mode),
                 if (config$mode == "SyntheticCDM") "TEST=true: synthetic CDM only; real DB connectivity was not tested."),
               success_path)
    cat("PASS: every role produced valid results\n")
}

if (sys.nframe() == 0L) {
    args <- commandArgs(trailingOnly = TRUE)
    stopifnot(length(args) == 1L)
    fp_verify_results(jsonlite::fromJSON(args[1]))
}
