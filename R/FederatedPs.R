#' Fit propensity scores on fixed inputs in one R process
#'
#' @param data Output of \code{\link{preparePsData}}.
#' @param method `"simulation"` jointly updates two local Cyclops states in this
#'   process; `"pooled"` and `"local"` use the existing normal Cyclops fit.
#' @param priorVariance One finite positive, fixed Laplace variance.
#' @param control Cyclops CPU CCD control using Lange convergence, one thread,
#'   and no screening or cross-validation.
#' @param startingCoefficients Finite coefficients named exactly
#'   `c("(Intercept)", as.character(data$covariateIds))` after zero exclusion.
#'
#' @details
#' This function is a same-process synthetic simulation, not remote federated
#' execution. Simulation checks the five patched exports once per invocation;
#' a version string alone cannot identify the required Cyclops build. No silent
#' fallback, installation, or private Cyclops calls are used.
#'
#' Local likelihoods are summed and the common prior is included once in the
#' global objective. The existing Lange stopping rule is not a KKT threshold.
#' State agreement uses fixed absolute and relative tolerances of `1e-10`.
#' Final PS values are raw existing Cyclops predictions joined by explicit row
#' keys to the original population, preserving its columns, order, and metadata.
#'
#' @return A list containing `populations`, plain numeric `models` diagnostics,
#'   `method`, `rowMap`, `excludedIds`, and the loaded `cyclopsPath`. Models have
#'   coefficients, iterations, return flag, log likelihood, log prior, and
#'   negative log-posterior `objective`. Native states are not returned or saved.
#' @export
fitPs <- function(data, method = c("simulation", "pooled", "local"),
                  priorVariance = 1,
                  control = Cyclops::createControl(convergenceType = "lange"),
                  startingCoefficients) {
    method <- match.arg(method)
    if (method == "simulation") {
        required <- c("initializeCyclopsCoordinateDescent", "getCyclopsCoordinateStatistics",
            "updateCyclopsCoordinate", "checkCyclopsCoordinateConvergence", "getCyclopsCoordinateFit")
        missing <- setdiff(required, getNamespaceExports("Cyclops"))
        if (length(missing)) stop("Patched Cyclops coordinate APIs are required. Apply ",
            "patches/cyclops-coordinate-descent.patch to commit ",
            "89dd48b18fcaa8cc4d88f235b1da38459ab912a3 and install into a separate library. Missing: ",
            paste(missing, collapse = ", "))
    }
    if (!is.list(data) || length(data$sites) != 2L || is.null(names(data$sites))) {
        stop("data must be returned by preparePsData")
    }
    features <- as.character(data$covariateIds)
    for (site in data$sites) {
        if (!inherits(site$x, "dgCMatrix") || !identical(colnames(site$x), features) ||
            !identical(rownames(site$x), names(site$y)) ||
            !is.numeric(site$y) || any(!is.finite(site$y)) ||
            any(!site$y %in% c(0, 1)) || length(unique(site$y)) != 2L ||
            !setequal(rownames(site$x), as.character(site$population$rowId)) ||
            anyDuplicated(site$population$rowId) || any(!is.finite(site$x@x)) ||
            !identical(unname(site$y), as.numeric(site$population$treatment[
                match(rownames(site$x), as.character(site$population$rowId))]))) {
            stop("Prepared sparse rows, treatment, or feature order no longer match")
        }
    }
    if (!identical(data$rowMap, .psRowMap(data$sites))) {
        stop("Pooled site/rowId map no longer matches the sparse rows")
    }
    if (!is.numeric(priorVariance) || length(priorVariance) != 1L ||
        !is.finite(priorVariance) || priorVariance <= 0) stop("priorVariance must be finite and positive")
    coefficientNames <- c("(Intercept)", features)
    if (!is.numeric(startingCoefficients) || !is.null(dim(startingCoefficients)) ||
        !identical(names(startingCoefficients), coefficientNames) ||
        any(!is.finite(startingCoefficients))) stop("startingCoefficients must follow the retained feature order")
    if (!inherits(control, "cyclopsControl") ||
        !identical(control$convergenceType, "lange") || !identical(control$algorithm, "ccd") ||
        !identical(control$useKKTSwindle, FALSE) || !identical(control$syncCV, FALSE) ||
        !is.null(control$setHook) || length(control$threads) != 1L ||
        !is.finite(control$threads) || control$threads != 1 ||
        length(control$tolerance) != 1L || !is.finite(control$tolerance) || control$tolerance <= 0 ||
        length(control$initialBound) != 1L || !is.finite(control$initialBound) || control$initialBound <= 0 ||
        length(control$maxIterations) != 1L || !is.finite(control$maxIterations) ||
        control$maxIterations < 1 || control$maxIterations != floor(control$maxIterations)) {
        stop("Use finite positive Lange CPU CCD controls, one thread and no screening")
    }
    prior <- Cyclops::createPrior("laplace", variance = priorVariance,
                                  exclude = "(Intercept)", useCrossValidation = FALSE)
    sites <- data$sites
    predictions <- vector("list", length(sites))
    names(predictions) <- names(sites)
    if (method == "local") {
        fits <- lapply(sites, function(site) .fitPsNormal(site$x, site$y,
            prior, control, startingCoefficients))
        predictions <- lapply(fits, stats::predict)
        models <- lapply(fits, .psModelResult)
    } else if (method == "pooled") {
        x <- do.call(rbind, lapply(sites, function(site) site$x))
        y <- unlist(lapply(sites, function(site) unname(site$y)), use.names = FALSE)
        rownames(x) <- data$rowMap$rowKey
        names(y) <- data$rowMap$rowKey
        fit <- .fitPsNormal(x, y, prior, control, startingCoefficients)
        ps <- stats::predict(fit)
        for (name in names(sites)) {
            map <- data$rowMap[data$rowMap$site == name, ]
            predictions[[name]] <- stats::setNames(ps[match(map$rowKey, names(ps))],
                                                    as.character(map$rowId))
        }
        models <- list(global = .psModelResult(fit))
    } else {
        states <- lapply(sites, function(site) Cyclops::initializeCyclopsCoordinateDescent(
            site$y, site$x, prior, control, startingCoefficients))
        fits <- lapply(states, Cyclops::getCyclopsCoordinateFit)
        likelihood <- sum(vapply(fits, function(fit) fit$log_likelihood, 0.0))
        done <- vapply(states, Cyclops::checkCyclopsCoordinateConvergence, TRUE,
                       logLikelihood = likelihood)
        while (!all(done)) {
            for (coordinate in coefficientNames) {
                statistics <- lapply(states, Cyclops::getCyclopsCoordinateStatistics,
                                     covariate = coordinate)
                .checkPsAgreement(statistics[[1L]][3:4], statistics[[2L]][3:4])
                total <- Reduce(`+`, lapply(statistics, function(value) value[1:2]))
                updates <- lapply(states, Cyclops::updateCyclopsCoordinate,
                    covariate = coordinate, gradient = total[["gradient"]],
                    curvature = total[["curvature"]])
                .checkPsAgreement(updates[[1L]], updates[[2L]])
            }
            fits <- lapply(states, Cyclops::getCyclopsCoordinateFit)
            .checkPsAgreement(stats::coef(fits[[1L]], ignoreConvergence = TRUE),
                              stats::coef(fits[[2L]], ignoreConvergence = TRUE))
            .checkPsAgreement(fits[[1L]]$log_prior, fits[[2L]]$log_prior)
            likelihood <- sum(vapply(fits, function(fit) fit$log_likelihood, 0.0))
            done <- vapply(states, Cyclops::checkCyclopsCoordinateConvergence, TRUE,
                           logLikelihood = likelihood)
            if (length(unique(done)) != 1L) stop("Site convergence states disagree")
        }
        fits <- lapply(states, Cyclops::getCyclopsCoordinateFit)
        localResults <- lapply(fits, .psModelResult)
        if (length(unique(vapply(localResults, function(x) x$iterations, 0.0))) != 1L) {
            stop("Site iteration states disagree")
        }
        predictions <- lapply(fits, stats::predict)
        global <- localResults[[1L]]
        global$logLikelihood <- sum(vapply(localResults, function(x) x$logLikelihood, 0.0))
        global$objective <- -(global$logLikelihood + global$logPrior)
        models <- list(global = global)
    }
    populations <- lapply(names(sites), function(name) {
        population <- sites[[name]]$population
        ps <- predictions[[name]]
        if (is.null(names(ps)) || anyDuplicated(names(ps)) ||
            !setequal(names(ps), as.character(population$rowId)) ||
            any(!is.finite(ps)) || any(ps <= 0 | ps >= 1)) {
            stop("Raw prediction row keys or probabilities are invalid")
        }
        population$propensityScore <- unname(ps[match(as.character(population$rowId), names(ps))])
        population
    })
    names(populations) <- names(sites)
    list(populations = populations, models = models, method = method,
        rowMap = data$rowMap, excludedIds = data$excludedIds,
        cyclopsPath = find.package("Cyclops"))
}

.fitPsNormal <- function(x, y, prior, control, startingCoefficients) {
    # The formula path marks the common intercept for the ordinary fit.
    frame <- data.frame(treatment = unname(y), row.names = rownames(x))
    cyclopsData <- Cyclops::createCyclopsData(treatment ~ 1, data = frame,
        sx = x, modelType = "lr", floatingPoint = 64)
    cyclopsData$coefficientNames <- names(startingCoefficients)
    Cyclops::fitCyclopsModel(cyclopsData, prior = prior, control = control,
        startingCoefficients = unname(startingCoefficients))
}

.psModelResult <- function(fit) {
    if (!identical(fit$return_flag, "SUCCESS")) stop("Cyclops did not converge: ", fit$return_flag)
    list(coefficients = stats::coef(fit), iterations = fit$iterations,
        returnFlag = fit$return_flag, logLikelihood = fit$log_likelihood,
        logPrior = fit$log_prior, objective = -(fit$log_likelihood + fit$log_prior))
}

.checkPsAgreement <- function(first, second) {
    if (length(first) != length(second) || any(!is.finite(c(first, second))) ||
        any(abs(first - second) > 1e-10 + 1e-10 * pmax(abs(first), abs(second)))) {
        stop("Site coefficient, bound, increment, or prior states disagree")
    }
    invisible(NULL)
}
