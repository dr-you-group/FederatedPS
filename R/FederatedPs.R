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
        .checkPsCoordinateApis()
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
        .joinPsPopulation(sites[[name]]$population, predictions[[name]])
    })
    names(populations) <- names(sites)
    list(populations = populations, models = models, method = method,
        rowMap = data$rowMap, excludedIds = data$excludedIds,
        cyclopsPath = find.package("Cyclops"))
}

.joinPsPopulation <- function(population, ps) {
    if (is.null(names(ps)) || anyDuplicated(names(ps)) ||
        !setequal(names(ps), as.character(population$rowId)) ||
        any(!is.finite(ps)) || any(ps <= 0 | ps >= 1)) {
        stop("Raw prediction row keys or probabilities are invalid")
    }
    population$propensityScore <- unname(ps[match(as.character(population$rowId), names(ps))])
    population
}

#' Joint synthetic PS fitting through two DataSHIELD R sessions
#'
#' @param connections Two named, active DSI/DSOpal connections, one per site.
#' @param inputSymbol Name of an existing approved site-local input on each server.
#' @param runId A new alphanumeric run identifier, starting with a letter.
#' @details This C1 research interface receives no patient-level input or PS.
#'   Each worker constructs its sparse/native state once. The loop uses only
#'   registered assign and aggregate methods, one coordinate at a time, with
#'   fixed absolute/relative state tolerances of `1e-10`. Seventeen decimal
#'   digits preserve numeric request precision. opalr retries are disabled for
#'   the call and restored on exit. Any failed response terminates the run;
#'   an existing run symbol cannot be overwritten or resumed.
#'
#'   The global objective includes the sum of site likelihoods and one prior.
#'   Lange convergence is not a KKT test. PS and matching remain on the workers;
#'   the separate C1 evaluation uses registered site evaluation functions.
#'   This is a research interface, not a hospital deployment or a
#'   disclosure-control guarantee. Gradient release needs security review.
#' @param returnPartial Return a diagnostic partial result only when both
#'   workers terminate consistently with `MAX_ITERATIONS` at the same complete
#'   sweep. The default raises a nonconvergence error. Partial models retain
#'   `returnFlag = "MAX_ITERATIONS"` and `converged = FALSE`; they cannot resume
#'   training or enter matching. Other failures always raise an error.
#' @return Plain global model, run/state identifiers, site process metadata,
#'   coordinate statistics and timings for the small C1 numerical comparison,
#'   and logical per-site API call counts. These counts are not measured network
#'   bytes; the integration script separately checks the Opal request log.
#'   `model$iterations`, `step` and `sweepSeconds` record completed sweeps and
#'   coordinate cycles; the initial convergence check does not count as a sweep.
#' @export
fitPsDataShield <- function(connections, inputSymbol, runId, returnPartial = FALSE) {
    if (!is.logical(returnPartial) || length(returnPartial) != 1L || is.na(returnPartial)) {
        stop("returnPartial must be TRUE or FALSE")
    }
    .checkPsDataShieldInputs(connections, inputSymbol, runId)
    previous <- options(opal.retry.times = 1L)
    on.exit(options(previous), add = TRUE)
    sites <- names(connections)
    stateSymbol <- paste0("ps_", runId)
    initializationStart <- proc.time()[["elapsed"]]
    # dsHasSession() only tests the client's cached ID. Query the server once
    # without creating a session when an ID is missing or has been deleted.
    if (!all(vapply(connections, function(conn) opalr::opal.session_exists(conn@opal), TRUE))) {
        stop("A worker session is unavailable")
    }
    symbols <- DSI::datashield.symbols(connections)
    if (any(vapply(symbols, function(x) stateSymbol %in% x, TRUE))) {
        stop("Run state already exists; start a new run with new sessions")
    }
    calls <- matrix(0L, 2L, 5L, dimnames = list(sites,
        c("initialize", "statistics", "update", "status", "convergence")))
    DSI::datashield.assign.expr(connections, stateSymbol,
        sprintf('initializePsSiteDS(%s, "%s")', inputSymbol, runId), async = FALSE)
    calls[, "initialize"] <- 1L
    status <- DSI::datashield.aggregate(connections,
        sprintf('getPsSiteStatusDS(%s, "%s", 0)', stateSymbol, runId), async = FALSE)
    calls[, "status"] <- calls[, "status"] + 1L
    status <- .checkPsReplies(status, sites, runId, 0)
    if (!identical(status[[1]]$specification, status[[2]]$specification)) {
        stop("Site feature order, scaling, prior or control settings disagree")
    }
    processes <- lapply(status, function(x) x$process)
    keys <- vapply(processes, function(x) paste(x$host, x$pid), "")
    if (length(unique(keys)) != 2L || paste(unname(Sys.info()["nodename"]), Sys.getpid()) %in% keys) {
        stop("C1 requires two distinct worker R processes and a separate coordinator")
    }
    coordinates <- names(status[[1]]$specification$settings$startingCoefficients)
    .checkPsAgreement(status[[1]]$logPrior, status[[2]]$logPrior)
    likelihood <- sum(vapply(status, function(x) x$logLikelihood, 0.0))
    DSI::datashield.assign.expr(connections, stateSymbol,
        sprintf('checkPsSiteConvergenceDS(%s, "%s", 0, %.17g)', stateSymbol, runId, likelihood), async = FALSE)
    calls[, "convergence"] <- 1L
    initializationSeconds <- proc.time()[["elapsed"]] - initializationStart
    trainingStart <- proc.time()[["elapsed"]]
    step <- 0L
    sweeps <- list()
    sweepSeconds <- numeric()
    repeat {
        status <- DSI::datashield.aggregate(connections,
            sprintf('getPsSiteStatusDS(%s, "%s", %d)', stateSymbol, runId, step), async = FALSE)
        calls[, "status"] <- calls[, "status"] + 1L
        status <- .checkPsReplies(status, sites, runId, step)
        done <- vapply(status, function(x) x$done, TRUE)
        if (length(unique(done)) != 1L) stop("Site convergence states disagree")
        if (all(done)) break
        sweepStart <- proc.time()[["elapsed"]]
        checks <- matrix(NA_real_, length(coordinates), 6L,
            dimnames = list(NULL, c("gradient", "curvature", "increment", "coefficient", "bound", "seconds")))
        for (j in seq_along(coordinates)) {
            cycleStart <- proc.time()[["elapsed"]]
            statistics <- DSI::datashield.aggregate(connections,
                sprintf('getPsSiteStatisticsDS(%s, "%s", %d, %d)', stateSymbol, runId, step, j), async = FALSE)
            calls[, "statistics"] <- calls[, "statistics"] + 1L
            statistics <- .checkPsReplies(statistics, sites, runId, step)
            values <- lapply(statistics, function(x) x$statistics)
            if (any(!vapply(values, function(x) is.numeric(x) && length(x) == 4L &&
                identical(names(x), c("gradient", "curvature", "coefficient", "bound")) &&
                all(is.finite(x)) && x[["curvature"]] >= 0, TRUE))) stop("Invalid coordinate statistics")
            .checkPsAgreement(values[[1]][3:4], values[[2]][3:4])
            total <- Reduce(`+`, lapply(values, function(x) x[1:2]))
            if (any(!is.finite(total)) || total[["curvature"]] <= 0) stop("Invalid global coordinate curvature")
            DSI::datashield.assign.expr(connections, stateSymbol,
                sprintf('updatePsSiteDS(%s, "%s", %d, %d, %.17g, %.17g)',
                    stateSymbol, runId, step, j, total[[1]], total[[2]]), async = FALSE)
            calls[, "update"] <- calls[, "update"] + 1L
            step <- step + 1L
            status <- DSI::datashield.aggregate(connections,
                sprintf('getPsSiteStatusDS(%s, "%s", %d)', stateSymbol, runId, step), async = FALSE)
            calls[, "status"] <- calls[, "status"] + 1L
            status <- .checkPsReplies(status, sites, runId, step)
            if (any(!vapply(status, function(x) is.numeric(x$update) &&
                identical(names(x$update), c("increment", "coefficient", "bound")) &&
                all(is.finite(x$update)), TRUE))) stop("Invalid coordinate update response")
            .checkPsAgreement(status[[1]]$update, status[[2]]$update)
            checks[j, ] <- c(total, status[[1]]$update, proc.time()[["elapsed"]] - cycleStart)
        }
        .checkPsAgreement(status[[1]]$logPrior, status[[2]]$logPrior)
        likelihood <- sum(vapply(status, function(x) x$logLikelihood, 0.0))
        DSI::datashield.assign.expr(connections, stateSymbol,
            sprintf('checkPsSiteConvergenceDS(%s, "%s", %d, %.17g)',
                stateSymbol, runId, step, likelihood), async = FALSE)
        calls[, "convergence"] <- calls[, "convergence"] + 1L
        sweeps[[length(sweeps) + 1L]] <- checks
        sweepSeconds <- c(sweepSeconds, proc.time()[["elapsed"]] - sweepStart)
    }
    model <- status[[1]]$model
    if (any(!vapply(status, function(x) identical(x$phase, "finished") &&
        identical(x$model$returnFlag, model$returnFlag) && x$nextCoordinate == 1L &&
        x$model$iterations == length(sweeps) && step == x$model$iterations * length(coordinates), TRUE))) {
        stop("Site terminal states or complete sweep counts disagree")
    }
    .checkPsAgreement(model$coefficients, status[[2]]$model$coefficients)
    .checkPsAgreement(c(model$logPrior, model$iterations),
        c(status[[2]]$model$logPrior, status[[2]]$model$iterations))
    model$logLikelihood <- sum(vapply(status, function(x) x$logLikelihood, 0.0))
    model$objective <- -(model$logLikelihood + model$logPrior)
    .checkPsAgreement(model$coefficients, sweeps[[length(sweeps)]][, "coefficient"])
    if (!is.finite(model$objective)) stop("Nonfinite terminal global objective")
    if (identical(model$returnFlag, "MAX_ITERATIONS") && !returnPartial) {
        stop("Cyclops did not converge: MAX_ITERATIONS; consistent terminal workers remain readable. ",
            "Use returnPartial = TRUE on a new run for a diagnostic partial result.")
    }
    list(model = model, runId = runId, stateSymbol = stateSymbol, step = step,
        processes = processes, initializations = vapply(status, function(x) x$initializations, 0L),
        coordinates = do.call(rbind, sweeps), calls = calls,
        initializationSeconds = initializationSeconds, sweepSeconds = sweepSeconds,
        trainingSeconds = proc.time()[["elapsed"]] - trainingStart)
}

.checkPsReplies <- function(values, sites, runId, step) {
    if (!is.list(values) || length(values) != length(sites) ||
        anyDuplicated(names(values)) || !setequal(names(values), sites)) stop("Missing or duplicate site response")
    values <- values[sites]
    for (name in sites) {
        x <- values[[name]]
        if (!is.list(x) || !identical(x$site, name) || !identical(x$runId, runId) ||
            !is.numeric(x$step) || length(x$step) != 1L || !is.finite(x$step) || x$step != step) {
            stop("Stale or mismatched site/run/step response")
        }
        if (!is.null(x$initializations) && x$initializations != 1L) stop("Worker state was reinitialized")
    }
    values
}

.checkPsDataShieldInputs <- function(connections, inputSymbol, runId) {
    if (!is.list(connections) || length(connections) != 2L ||
        is.null(names(connections)) || anyNA(names(connections)) ||
        any(!nzchar(names(connections))) || anyDuplicated(names(connections))) {
        stop("Exactly two uniquely named site connections are required")
    }
    if (!is.character(inputSymbol) || length(inputSymbol) != 1L || is.na(inputSymbol) ||
        !grepl("^[A-Za-z][A-Za-z0-9._]*$", inputSymbol) ||
        !is.character(runId) || length(runId) != 1L || is.na(runId) ||
        !grepl("^[A-Za-z][A-Za-z0-9]*$", runId)) stop("Invalid input symbol or run identifier")
    if (!requireNamespace("DSI", quietly = TRUE) ||
        !requireNamespace("DSOpal", quietly = TRUE) ||
        !requireNamespace("opalr", quietly = TRUE)) stop("Install DSI, DSOpal and opalr for C1 execution")
    if (!all(vapply(connections, inherits, TRUE, "OpalConnection"))) {
        stop("C1 requires DSI/DSOpal connections")
    }
}

#' Training-only preprocessing and fixed-grid global CV through DataSHIELD
#'
#' @inheritParams fitPsDataShield
#' @param priorVariances Positive fixed grid, visited in increasing order.
#' @param folds Number of site-local treatment-stratified folds.
#' @param minFraction Training nonzero frequency threshold, inclusive.
#' @param seed Common deterministic seed; rows are sorted locally and comparator
#'   then target groups are permuted separately. Fold assignments stay local.
#' @param maxFitSeconds R elapsed-time limit for each fixed-prior fit.
#' @details Uses existing `fitPsDataShield(..., returnPartial = FALSE)` for every
#'   candidate/fold and the final full-population refit. Each fit starts at zero
#'   in a new native state; transformed fold inputs are reused. All fits must
#'   succeed. No candidate is omitted after a failure. Validation scores are
#'   summed unpenalized logistic loss divided by the total validation count.
#'   Scores within `1e-10` of the minimum select the smaller variance.
#'
#'   Input is a worker-local synthetic input with candidate references including
#'   `timeWindow`, `valueType` (binary/count/continuous) and `isCollected = TRUE`.
#'   Values must be finite and nonnegative; missing records mean zero. Supplied
#'   control settings are preserved. Filtering/scaling are estimated anew from
#'   training rows in each fold, then from all rows for the final refit. This is
#'   not Cyclops' default internal CV or full FeatureExtraction tidying.
#' @return Plain preprocessing summaries, candidate scores, selected variance,
#'   fixed-prior fit diagnostics and final fit. No individual data or native
#'   state is returned. Matching is a separate site-local operation on SUCCESS.
#' @export
fitPsDataShieldCv <- function(connections, inputSymbol, runId,
    priorVariances = c(0.1, 1), folds = 2L, minFraction = 0.05,
    seed = 20260907L, maxFitSeconds = 300) {
    .checkPsDataShieldInputs(connections, inputSymbol, runId)
    if (!is.numeric(priorVariances) || !length(priorVariances) ||
        any(!is.finite(priorVariances)) || any(priorVariances <= 0) || anyDuplicated(priorVariances) ||
        !is.numeric(folds) || length(folds) != 1L || !is.finite(folds) || folds < 2 || folds != floor(folds) ||
        !is.numeric(seed) || length(seed) != 1L || !is.finite(seed) || seed < 0 ||
        seed > .Machine$integer.max || seed != floor(seed) ||
        !is.numeric(minFraction) || length(minFraction) != 1L || !is.finite(minFraction) ||
        minFraction < 0 || minFraction > 1 || !is.numeric(maxFitSeconds) ||
        length(maxFitSeconds) != 1L || !is.finite(maxFitSeconds) || maxFitSeconds <= 0) {
        stop("Invalid fixed CV grid, folds, threshold, seed or time limit")
    }
    previous <- options(opal.retry.times = 1L)
    on.exit(options(previous), add = TRUE)
    sites <- names(connections)
    rawSymbol <- paste0("cv_", runId)
    symbols <- DSI::datashield.symbols(connections)
    if (any(vapply(symbols, function(x) any(startsWith(x, rawSymbol)), TRUE))) stop("CV run already exists")
    DSI::datashield.assign.expr(connections, rawSymbol,
        sprintf('preparePsCvDS(%s, %d, %d)', inputSymbol, folds, seed), async = FALSE)
    grid <- sort(priorVariances)
    specifications <- fits <- list()
    losses <- list()
    validationCounts <- stats::setNames(rep(0, length(sites)), sites)
    totalCounts <- NULL
    # Fold zero is the final refit, reached only after all CV fits succeeded.
    for (fold in c(seq_len(folds), 0L)) {
        summaries <- DSI::datashield.aggregate(connections,
            sprintf('getPsPreprocessingDS(%s, %d)', rawSymbol, fold), async = FALSE)
        if (!setequal(names(summaries), sites) || length(summaries) != length(sites) ||
            anyDuplicated(names(summaries))) stop("Missing or duplicate preprocessing site")
        summaries <- summaries[sites]
        specification <- combinePsSummaries(summaries, minFraction)
        if (specification$fold != fold) stop("Stale preprocessing fold")
        counts <- vapply(summaries, function(x) x$totalN, 0.0)
        if (is.null(totalCounts)) totalCounts <- counts
        if (!identical(counts, totalCounts)) stop("CV populations changed between folds")
        if (fold != 0L) validationCounts <- validationCounts +
            vapply(summaries, function(x) x$validationN, 0.0)
        specifications[[as.character(fold)]] <- specification
        preparedSymbol <- paste0(rawSymbol, "f", fold)
        DSI::datashield.assign.expr(connections, preparedSymbol,
            sprintf('applyPsPreprocessingDS(%s, %d, c(%s), c(%s))', rawSymbol, fold,
                paste(sprintf("%.17g", specification$covariateIds), collapse = ","),
                paste(sprintf("%.17g", specification$scales), collapse = ",")), async = FALSE)
        candidates <- if (fold == 0L) selectedVariance else grid
        for (variance in candidates) {
            index <- match(variance, grid)
            fitRun <- paste0(runId, "f", fold, "v", index)
            fitInput <- paste0(preparedSymbol, "v", index)
            DSI::datashield.assign.expr(connections, fitInput,
                sprintf('setPsPriorDS(%s, %.17g)', preparedSymbol, variance), async = FALSE)
            setTimeLimit(elapsed = maxFitSeconds, transient = FALSE)
            fit <- tryCatch(fitPsDataShield(connections, fitInput, fitRun, returnPartial = FALSE),
                finally = setTimeLimit(cpu = Inf, elapsed = Inf, transient = FALSE))
            if (!identical(fit$model$returnFlag, "SUCCESS")) stop("CV requires SUCCESS for every fit")
            fit$inputSymbol <- fitInput
            fits[[fitRun]] <- fit
            if (fold != 0L) {
                validation <- DSI::datashield.aggregate(connections,
                    sprintf('getPsValidationDS(%s, %s, "%s", %d)', fit$stateSymbol,
                        fitInput, fitRun, fit$step), async = FALSE)
                validation <- .checkPsReplies(validation, sites, fitRun, fit$step)
                for (name in sites) {
                    value <- validation[[name]]
                    if (!identical(value$fold, as.integer(fold)) || !is.numeric(value$loss) ||
                        length(value$loss) != 1L || !is.finite(value$loss) || value$loss < 0 ||
                        !is.numeric(value$n) || length(value$n) != 1L || !is.finite(value$n) ||
                        value$n <= 0 || value$n != summaries[[name]]$validationN) stop("Invalid validation loss or count")
                    losses[[length(losses) + 1L]] <- data.frame(site = name, fold = fold,
                        priorVariance = variance, loss = value$loss, n = value$n)
                }
            }
        }
        if (fold == folds) {
            if (!identical(validationCounts, totalCounts)) stop("Each population must contribute validation exactly once")
            cv <- do.call(rbind, losses)
            scores <- data.frame(priorVariance = grid, score = vapply(grid, function(variance) {
                rows <- cv$priorVariance == variance
                sum(cv$loss[rows]) / sum(cv$n[rows])
            }, 0.0))
            selectedVariance <- min(scores$priorVariance[scores$score <= min(scores$score) + 1e-10])
        }
    }
    list(preprocessing = specifications, validation = cv, scores = scores,
        selectedVariance = selectedVariance, fits = fits, finalFit = fit)
}

.checkPsCoordinateApis <- function() {
    required <- c("initializeCyclopsCoordinateDescent", "getCyclopsCoordinateStatistics",
        "updateCyclopsCoordinate", "checkCyclopsCoordinateConvergence", "getCyclopsCoordinateFit")
    missing <- setdiff(required, getNamespaceExports("Cyclops"))
    if (length(missing)) stop("Patched Cyclops coordinate APIs are required. Apply ",
        "patches/cyclops-coordinate-descent.patch to commit ",
        "89dd48b18fcaa8cc4d88f235b1da38459ab912a3 and install into a separate library. Missing: ",
        paste(missing, collapse = ", "))
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
