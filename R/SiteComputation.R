#' Research DataSHIELD site calculations
#'
#' @description Research server registration functions. The CDM loader is
#'   disabled unless explicitly enabled by the local server administrator.
#'   These functions do not establish hospital security boundaries or remove
#'   gradient and intermediate-model disclosure risks.
#' @param input Server-local plain input, including the agreed feature
#'   specification and fixed fitting settings.
#' @param state Server-local state created by `initializePsSiteDS()`.
#' @param runId One nonempty run identifier.
#' @param step Number of coordinate updates already completed.
#' @param covariate One-based coefficient position in the agreed coordinate order.
#' @param gradient,curvature Summed coordinate statistics from all sites.
#' @param logLikelihood Sum of site log likelihoods, without the prior.
#' @param zero,negative,tiny,noninteger,nearOne Finite numeric transport probes.
#' @param folds,seed Number of stratified folds and deterministic local seed.
#'   Explicit CDM inputs accept `folds = 0` for full-data preprocessing without CV.
#' @param fold Validation fold, or zero for full-population final preprocessing.
#' @param covariateIds,scales Common retained IDs and positive training maxima.
#' @param priorVariance Fixed positive Laplace variance for a fresh fit.
#' @details
#' Initialization and mutation are registered as assign methods. Read-only
#' statistics and status are aggregate methods. Native state remains in the
#' session, and no patient predictions, row identifiers, or external pointers
#' are returned by aggregate methods. A stale or failed update cannot be retried.
#' A consistent `MAX_ITERATIONS` termination remains readable but cannot be
#' updated. Synthetic sweep evaluation compares the live native predictions;
#' it does not run matching on a nonconverged fit.
#'
#' The setup-only loader has no path argument. It reads the administrator-set
#' `FEDERATEDPS_C1_INPUT` file in a dedicated test container. Only plain synthetic
#' tables and settings belong in that file; it is not a general file loader.
#' @return Assign functions return an input or state for storage in the server
#'   session. Aggregate functions return only numerical checks and run metadata.
#' @keywords internal
#' @name psSiteComputation
NULL

#' @rdname psSiteComputation
#' @export
loadPsSyntheticDS <- function() {
    path <- Sys.getenv("FEDERATEDPS_C1_INPUT")
    if (!identical(path, "/opt/federatedps/input/site.rds")) {
        stop("C1 synthetic input is not configured by this test server")
    }
    input <- readRDS(path)
    if (!is.list(input) || !identical(input$synthetic, TRUE) ||
        !identical(paste0("c1-", input$name), Sys.getenv("ROCK_ID"))) {
        stop("Synthetic input does not belong to this C1 worker")
    }
    input
}

#' @rdname psSiteComputation
#' @export
loadPsCdmDS <- function() {
    path <- "/opt/federatedps/input/cdm-site.rds"
    if (!identical(Sys.getenv("FEDERATEDPS_DATA_MODE"), "cdm") ||
        !file.exists(path) || !identical(normalizePath(path), path) ||
        as.character(file.info(path)$mode) != "600" ||
        as.character(file.info(dirname(path))$mode) != "700") {
        stop("Protected CDM input is not enabled and privately configured on this worker")
    }
    input <- readRDS(path)
    if (!.psCdmInput(input) || !identical(paste0("c1-", input$name), Sys.getenv("ROCK_ID"))) {
        stop("CDM input does not belong to this worker")
    }
    input
}

.psCdmInput <- function(input) {
    is.list(input) && identical(input$synthetic, FALSE) &&
        identical(input$dataMode, "cdm") && identical(input$site$metadata$dataMode, "cdm")
}

#' @rdname psSiteComputation
#' @export
initializePsSiteDS <- function(input, runId) {
    .checkPsCoordinateApis()
    if (!is.list(input) || !(identical(input$synthetic, TRUE) || .psCdmInput(input)) ||
        !is.character(input$name) || length(input$name) != 1L || is.na(input$name) ||
        !nzchar(input$name) || !is.character(runId) || length(runId) != 1L ||
        is.na(runId) || !nzchar(runId) || !is.list(input$settings) ||
        is.null(input$excludedIds)) stop("Invalid site, run or agreed settings")
    settings <- input$settings
    control <- do.call(Cyclops::createControl, settings$control)
    prior <- Cyclops::createPrior("laplace", variance = settings$priorVariance,
        exclude = "(Intercept)", useCrossValidation = FALSE)
    reused <- !is.null(input$preparedSite) && isTRUE(input$cvPrepared)
    if (reused) {
        site <- input$preparedSite
    } else {
        prepared <- .preparePsSites(stats::setNames(list(input$site), input$name),
            input$covariateIds, input$scales, excludedIds = input$excludedIds)
        site <- prepared$sites[[1L]]
    }
    complete <- FALSE
    on.exit(if (!complete && !reused) Andromeda::close(site$cohortMethodData), add = TRUE)
    state <- new.env(parent = emptyenv())
    state$ccd <- Cyclops::initializeCyclopsCoordinateDescent(site$y, site$x,
        prior, control, settings$startingCoefficients)
    state$site <- site
    state$name <- input$name
    state$runId <- runId
    state$step <- 0L
    state$failed <- FALSE
    state$phase <- "sweep"
    state$lastUpdate <- NULL
    state$done <- FALSE
    state$initializations <- 1L
    state$privateData <- .psCdmInput(input)
    state$coordinates <- names(settings$startingCoefficients)
    state$specification <- list(covariateIds = input$covariateIds,
        scales = input$scales, excludedIds = input$excludedIds, settings = settings,
        covariateRef = input$site$covariateRef, analysisRef = input$site$analysisRef)
    if (reused) {
        state$specification$covariateRef <- input$reference$covariateRef
        state$specification$analysisRef <- input$reference$analysisRef
        state$specification$trainingFold <- input$trainingFold
        state$specification$folds <- input$folds
        state$specification$seed <- input$seed
    }
    complete <- TRUE
    state
}

#' @rdname psSiteComputation
#' @export
preparePsCvDS <- function(input, folds, seed) {
    if (!is.list(input) || !(isTRUE(input$synthetic) || .psCdmInput(input)) || isTRUE(input$cvPrepared) ||
        !is.character(input$name) || length(input$name) != 1L || is.na(input$name) || !nzchar(input$name) ||
        !is.numeric(folds) || length(folds) != 1L || !is.finite(folds) ||
        (folds < 2 && !(folds == 0 && .psCdmInput(input))) || folds != floor(folds) ||
        !is.numeric(seed) || length(seed) != 1L || !is.finite(seed) || seed < 0 ||
        seed > .Machine$integer.max || seed != floor(seed) || !is.list(input$settings$control)) {
        stop("Invalid synthetic CV input, folds or seed")
    }
    ids <- .psIdKeys(input$covariateIds, "candidate covariateIds")
    prepared <- .preparePsSites(stats::setNames(list(input$site), input$name), input$covariateIds,
        stats::setNames(rep(1, length(ids)), ids), excludedIds = numeric())
    complete <- FALSE
    on.exit(if (!complete) Andromeda::close(prepared$sites[[1L]]$cohortMethodData), add = TRUE)
    raw <- prepared$sites[[1L]]
    if (any(raw$x@x < 0)) stop("Automatic preprocessing requires nonnegative values")
    ref <- input$site$covariateRef
    if (!all(c("timeWindow", "valueType", "isCollected") %in% names(ref)) ||
        anyNA(ref[c("timeWindow", "valueType", "isCollected")]) ||
        any(!nzchar(ref$timeWindow)) || any(!ref$valueType %in% c("binary", "count", "continuous")) ||
        !is.logical(ref$isCollected) || !all(ref$isCollected)) {
        stop("Automatic preprocessing requires timeWindow, valueType and explicit collection coverage")
    }
    if (any(tabulate(raw$y + 1L, nbins = 2L) < folds)) stop("Each treatment group must occur in every fold")
    types <- ref$valueType[match(colnames(raw$x), as.character(ref$covariateId))]
    for (j in seq_along(types)) {
        from <- raw$x@p[j] + 1L; to <- raw$x@p[j + 1L]
        values <- if (from > to) numeric() else raw$x@x[from:to]
        if ((types[j] == "binary" && any(!values %in% c(0, 1))) ||
            (types[j] == "count" && any(values != floor(values)))) stop("Values disagree with declared feature type")
    }
    hadSeed <- exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)
    if (hadSeed) savedSeed <- get(".Random.seed", envir = .GlobalEnv)
    on.exit(if (hadSeed) assign(".Random.seed", savedSeed, envir = .GlobalEnv) else
        rm(".Random.seed", envir = .GlobalEnv), add = TRUE)
    set.seed(seed)
    foldId <- integer(length(raw$y))
    # Sparse rows are already sorted by rowId. Draw comparator first, then target.
    for (group in if (folds == 0) numeric() else c(0, 1)) {
        rows <- which(raw$y == group)
        foldId[rows[sample.int(length(rows))]] <- rep(seq_len(folds), length.out = length(rows))
    }
    input$raw <- raw
    input$foldId <- foldId
    input$folds <- as.integer(folds)
    input$seed <- as.integer(seed)
    input$cvPrepared <- TRUE
    input$reference <- list(covariateRef = ref[match(ids, as.character(ref$covariateId)), ],
        analysisRef = input$site$analysisRef[order(input$site$analysisRef$analysisId), ])
    rownames(input$reference$covariateRef) <- rownames(input$reference$analysisRef) <- NULL
    complete <- TRUE
    input
}

#' @rdname psSiteComputation
#' @export
getPsPreprocessingDS <- function(input, fold) .psTrainingSummary(input, fold)

#' @rdname psSiteComputation
#' @export
applyPsPreprocessingDS <- function(input, fold, covariateIds, scales) {
    .psApplyTrainingSpec(input, fold, covariateIds, scales)
}

#' @rdname psSiteComputation
#' @export
setPsPriorDS <- function(input, priorVariance) {
    if (!isTRUE(input$cvPrepared) || is.null(input$preparedSite) ||
        !is.numeric(priorVariance) || length(priorVariance) != 1L ||
        !is.finite(priorVariance) || priorVariance <= 0) stop("Invalid prepared fold or variance")
    input$settings$priorVariance <- priorVariance
    input
}

.psValidationLoss <- function(eta, y) {
    if (!is.numeric(eta) || !is.numeric(y) || !length(y) || length(eta) != length(y) ||
        any(!is.finite(c(eta, y))) || any(!y %in% c(0, 1))) stop("Invalid validation predictor or label")
    # softplus(eta) - y*eta without subtracting two large, equal numbers.
    loss <- sum(ifelse(y == 1, pmax(-eta, 0), pmax(eta, 0)) + log1p(exp(-abs(eta))))
    if (!is.finite(loss)) stop("Nonfinite validation loss")
    loss
}

#' @rdname psSiteComputation
#' @export
getPsValidationDS <- function(state, input, runId, step) {
    .checkPsSiteStep(state, runId, step)
    if (!identical(state$name, input$name) || !isTRUE(input$cvPrepared) ||
        input$trainingFold == 0 || !identical(input$trainingFold, state$specification$trainingFold) ||
        !identical(input$settings, state$specification$settings) ||
        !identical(colnames(input$validation$x), state$coordinates[-1L]) ||
        !identical(rownames(input$validation$x), names(input$validation$y))) stop("Validation fold or model mismatch")
    model <- .psSiteTerminalModel(state, Cyclops::getCyclopsCoordinateFit(state$ccd))
    if (!identical(model$returnFlag, "SUCCESS")) stop("Validation requires SUCCESS")
    eta <- as.numeric(input$validation$x %*% model$coefficients[-1L]) + model$coefficients[[1L]]
    list(site = state$name, runId = runId, step = state$step, fold = input$trainingFold,
        loss = .psValidationLoss(eta, input$validation$y), n = length(eta))
}

.checkPsSiteStep <- function(state, runId, step) {
    if (!is.environment(state) || !identical(state$runId, runId) ||
        !is.numeric(step) || length(step) != 1L || !is.finite(step) ||
        step != state$step || identical(state$failed, TRUE)) {
        stop("Invalid, stale, duplicate, or failed site/run/step")
    }
}

.psSiteCoordinate <- function(state, covariate) {
    if (!is.numeric(covariate) || length(covariate) != 1L ||
        !is.finite(covariate) || covariate != floor(covariate) ||
        covariate < 1 || covariate > length(state$coordinates)) {
        stop("Coordinate must be a position in the agreed feature order")
    }
    # DataSHIELD rejects parentheses in string arguments. Resolve the fixed
    # ordinal locally; no expression decoding or parser exception is needed.
    state$coordinates[[covariate]]
}

#' @rdname psSiteComputation
#' @export
getPsSiteStatisticsDS <- function(state, runId, step, covariate) {
    .checkPsSiteStep(state, runId, step)
    if (!identical(state$phase, "coordinate")) stop("Site is not ready for a coordinate")
    list(site = state$name, runId = runId, step = state$step,
        statistics = Cyclops::getCyclopsCoordinateStatistics(state$ccd,
            .psSiteCoordinate(state, covariate)))
}

#' @rdname psSiteComputation
#' @export
updatePsSiteDS <- function(state, runId, step, covariate, gradient, curvature) {
    tryCatch({
        .checkPsSiteStep(state, runId, step)
        if (!identical(state$phase, "coordinate")) stop("Site is not ready for an update")
        state$lastUpdate <- Cyclops::updateCyclopsCoordinate(state$ccd,
            .psSiteCoordinate(state, covariate),
            gradient = gradient, curvature = curvature)
        state$step <- state$step + 1L
        state$phase <- if (state$step %% length(state$coordinates) == 0L) "sweep" else "coordinate"
        state
    }, error = function(e) {
        if (is.environment(state)) state$failed <- TRUE
        stop(conditionMessage(e), call. = FALSE)
    })
}

#' @rdname psSiteComputation
#' @export
checkPsSiteConvergenceDS <- function(state, runId, step, logLikelihood) {
    tryCatch({
        .checkPsSiteStep(state, runId, step)
        if (!identical(state$phase, "sweep")) stop("Convergence requires a complete sweep")
        state$done <- Cyclops::checkCyclopsCoordinateConvergence(state$ccd,
            logLikelihood = logLikelihood)
        state$phase <- if (state$done) "finished" else "coordinate"
        if (state$done) .psSiteTerminalModel(state, Cyclops::getCyclopsCoordinateFit(state$ccd))
        state
    }, error = function(e) {
        if (is.environment(state)) state$failed <- TRUE
        stop(conditionMessage(e), call. = FALSE)
    })
}

#' @rdname psSiteComputation
#' @export
getPsSiteStatusDS <- function(state, runId, step) {
    .checkPsSiteStep(state, runId, step)
    result <- list(site = state$name, runId = runId, step = state$step,
        phase = state$phase, done = state$done, update = state$lastUpdate,
        initializations = state$initializations)
    if (state$step == 0L || state$phase %in% c("sweep", "finished")) {
        fit <- Cyclops::getCyclopsCoordinateFit(state$ccd)
        result$logLikelihood <- fit$log_likelihood
        result$logPrior <- fit$log_prior
        result$iterations <- fit$iterations
    }
    if (state$step == 0L) {
        result$specification <- state$specification
        result$process <- list(pid = Sys.getpid(), host = unname(Sys.info()["nodename"]),
            r = R.version.string, cyclops = find.package("Cyclops"),
            cyclopsNative = getLoadedDLLs()[["Cyclops"]][["path"]],
            federatedPs = find.package("FederatedPs"),
            returnPartialDefault = formals(fitPsDataShield)$returnPartial)
    }
    if (state$done) {
        result$model <- .psSiteTerminalModel(state, fit)
        result$nextCoordinate <- fit$nextCoordinate
    }
    result
}

.psSiteTerminalModel <- function(state, fit) {
    # This is a read-only boundary check, never another convergence check.
    if (!isTRUE(state$done) || !identical(state$phase, "finished") ||
        !isTRUE(fit$finished) || fit$nextCoordinate != 1L ||
        !is.finite(fit$iterations) || fit$iterations < 1L ||
        state$step != fit$iterations * length(state$coordinates) ||
        any(!is.finite(c(fit$log_likelihood, fit$log_prior, fit$convergence)))) {
        stop("Invalid terminal site state or incomplete sweep")
    }
    if (identical(fit$return_flag, "MAX_ITERATIONS")) {
        if (fit$iterations != fit$control$maxIterations) stop("Iteration limit and terminal state disagree")
        coefficients <- stats::coef(fit, ignoreConvergence = TRUE)
        model <- list(coefficients = coefficients, iterations = fit$iterations,
            returnFlag = fit$return_flag, logLikelihood = fit$log_likelihood,
            logPrior = fit$log_prior, objective = -(fit$log_likelihood + fit$log_prior),
            converged = FALSE)
    } else {
        model <- .psModelResult(fit)
    }
    if (!identical(names(model$coefficients), state$coordinates) ||
        any(!is.finite(model$coefficients))) stop("Invalid terminal coefficients")
    model
}

#' @rdname psSiteComputation
#' @export
checkPsPrecisionDS <- function(zero, negative, tiny, noninteger, nearOne) {
    values <- list(zero, negative, tiny, noninteger, nearOne)
    if (any(!vapply(values, function(x) is.numeric(x) && length(x) == 1L && is.finite(x), TRUE))) {
        stop("Precision probes must be finite numeric scalars")
    }
    unlist(values, use.names = FALSE)
}

#' @rdname psSiteComputation
#' @export
evaluatePsSiteDS <- function(state, input, runId, step) {
    .checkPsSiteStep(state, runId, step)
    if (!isTRUE(state$done) || !identical(state$phase, "finished") ||
        isTRUE(state$evaluationDone)) stop("Evaluation requires a completed, unevaluated run")
    evaluation <- input$evaluation
    fit <- Cyclops::getCyclopsCoordinateFit(state$ccd)
    model <- .psSiteTerminalModel(state, fit)
    if (isTRUE(state$privateData)) return(.evaluatePsCdmSite(state, input, model, fit, runId, step))
    if (is.list(evaluation) && identical(evaluation$type, "D")) {
        if (!isTRUE(input$cvPrepared) || !identical(input$name, state$name) ||
            !identical(input$trainingFold, state$specification$trainingFold) ||
            !identical(input$settings, state$specification$settings) ||
            !identical(model$returnFlag, "SUCCESS")) stop("D evaluation requires the corresponding successful CV fit")
        expected <- evaluation$folds[[as.character(input$trainingFold)]]
        errors <- list()
        for (part in c("train", "valid")) {
            actualX <- if (part == "train") state$site$x else input$validation$x
            expectedX <- expected[[part]]
            if (!inherits(expectedX, "dgCMatrix") || !identical(dimnames(actualX), dimnames(expectedX))) {
                stop("D evaluation sparse row or feature mapping differs")
            }
            positions <- Matrix::summary(actualX - expectedX)
            index <- cbind(positions$i, positions$j)
            errors[[paste0(part, "Transform")]] <- .psEvaluationError(
                as.numeric(actualX[index]), as.numeric(expectedX[index]), 1e-12)
        }
        beta <- evaluation$models[[paste(input$trainingFold, input$settings$priorVariance, sep = ":")]]$coefficients
        if (!identical(names(beta), state$coordinates)) stop("D evaluation coefficient mapping differs")
        before <- getPsSiteStatusDS(state, runId, step)
        prediction <- stats::predict(fit)
        if (!identical(names(prediction), rownames(state$site$x))) stop("Native prediction rows differ")
        linear <- as.numeric(state$site$x %*% model$coefficients[-1L]) + model$coefficients[[1L]]
        referenceLinear <- as.numeric(expected$train %*% beta[-1L]) + beta[[1L]]
        errors$rawPs <- .psEvaluationError(prediction, stats::plogis(referenceLinear), 1e-7)
        errors$linearPredictor <- .psEvaluationError(linear, referenceLinear, 1e-7)
        errors$nativeCache <- .psEvaluationError(prediction, stats::plogis(linear), 1e-7)
        if (!identical(before, getPsSiteStatusDS(state, runId, step)) ||
            !identical(prediction, stats::predict(Cyclops::getCyclopsCoordinateFit(state$ccd)))) {
            stop("D evaluation changed the native state")
        }
        state$dErrors <- do.call(cbind, errors)
        if (input$trainingFold != 0L) {
            state$evaluation <- list(errors = state$dErrors, matchingPerformed = FALSE,
                statusUnchanged = TRUE, nativePredictionUnchanged = TRUE)
            state$evaluationDone <- TRUE
            return(state)
        }
    }
    if (is.list(evaluation) && identical(evaluation$type, "sweep")) {
        if (!identical(input$synthetic, TRUE) || !identical(input$name, state$name) ||
            !identical(evaluation$step, state$step) ||
            !identical(names(evaluation$rawPs), rownames(state$site$x)) ||
            !identical(names(evaluation$linearPredictor), rownames(state$site$x))) {
            stop("Synthetic sweep reference does not match this site and step")
        }
        before <- getPsSiteStatusDS(state, runId, step)
        prediction <- stats::predict(fit) # Reads this run's live native cache.
        if (!identical(names(prediction), rownames(state$site$x)) ||
            any(!is.finite(prediction)) || any(prediction <= 0 | prediction >= 1)) {
            stop("Native prediction is nonfinite or outside the finite-logit range")
        }
        linear <- as.numeric(state$site$x %*% model$coefficients[-1L]) + model$coefficients[[1L]]
        # The public native accessor returns response-scale predictions. Their
        # inverse link checks the cached predictor without a new model or fit.
        comparisons <- list(rawPs = list(prediction, evaluation$rawPs),
            linearPredictor = list(stats::qlogis(prediction), evaluation$linearPredictor),
            cacheRawPs = list(prediction, stats::plogis(linear)),
            cacheLinearPredictor = list(stats::qlogis(prediction), linear))
        errors <- vapply(comparisons, function(pair) {
            a <- unname(pair[[1L]]); b <- unname(pair[[2L]])
            if (!is.numeric(b) || length(a) != length(b) || any(!is.finite(c(a, b)))) {
                stop("Invalid synthetic sweep reference values")
            }
            difference <- abs(a - b)
            ratio <- difference / (1e-7 + 1e-7 * pmax(abs(a), abs(b)))
            if (any(ratio > 1)) stop("Native cache differs from the synthetic sweep reference")
            c(absolute = max(difference), toleranceRatio = max(ratio))
        }, c(absolute = 0.0, toleranceRatio = 0.0))
        if (!identical(prediction, stats::predict(Cyclops::getCyclopsCoordinateFit(state$ccd))) ||
            !identical(before, getPsSiteStatusDS(state, runId, step))) {
            stop("Terminal status or native prediction changed during evaluation")
        }
        state$evaluation <- list(errors = errors, statusUnchanged = TRUE,
            nativePredictionUnchanged = TRUE, matchingPerformed = FALSE)
        state$evaluationDone <- TRUE
        return(state)
    }
    if (!identical(model$returnFlag, "SUCCESS")) stop("Matching requires a converged SUCCESS fit")
    if (!is.list(evaluation) || !identical(input$name, state$name) ||
        !identical(names(evaluation$populations), if (identical(evaluation$type, "D"))
            c("local", "pooled") else c("local", "pooled", "simulation"))) {
        stop("C1 evaluation requires this site's plain synthetic reference populations")
    }
    original <- state$site$population
    populations <- evaluation$populations
    for (population in populations) {
        if (!is.data.frame(population) || !all(names(original) %in% names(population)) ||
            !all(vapply(names(original), function(column) identical(population[[column]], original[[column]]), TRUE)) ||
            !identical(rownames(population), rownames(original)) ||
            !identical(attr(population, "metaData"), attr(original, "metaData")) ||
            !is.numeric(population$propensityScore) || any(!is.finite(population$propensityScore)) ||
            any(population$propensityScore <= 0 | population$propensityScore >= 1)) {
            stop("Synthetic reference PS no longer matches this site's original population")
        }
    }
    populations$remote <- .joinPsPopulation(original,
        stats::predict(Cyclops::getCyclopsCoordinateFit(state$ccd)))
    errors <- vapply(populations[intersect(c("pooled", "simulation"), names(populations))], function(population) {
        a <- populations$remote$propensityScore
        b <- population$propensityScore
        if (any(abs(a - b) > 1e-7 + 1e-7 * pmax(abs(a), abs(b)))) {
            stop("Remote raw PS differs from the fixed synthetic reference")
        }
        max(abs(a - b))
    }, 0.0)
    matching <- do.call(CohortMethod::createMatchOnPsArgs, evaluation$matching)
    balanceArgs <- do.call(CohortMethod::createComputeCovariateBalanceArgs, evaluation$balance)
    matched <- summaries <- vector("list", length(populations))
    names(matched) <- names(summaries) <- names(populations)
    meanError <- 0
    started <- proc.time()[["elapsed"]]
    long <- input$site$covariates
    for (method in names(populations)) {
        population <- populations[[method]]
        population <- population[order(population$rowId), ]
        after <- CohortMethod::matchOnPs(population, matching)
        repeated <- CohortMethod::matchOnPs(population, matching)
        if (!identical(after, repeated) || !all(after$rowId %in% original$rowId) ||
            any(table(after$stratumId, after$treatment) != 1) ||
            !all(c(0, 1) %in% after$treatment) ||
            !identical(after$propensityScore, population$propensityScore[match(after$rowId, population$rowId)])) {
            stop("Site matching or its PS/row connection is not reproducible")
        }
        balance <- CohortMethod::computeCovariateBalance(after, state$site$cohortMethodData, balanceArgs)
        if (identical(evaluation$type, "D")) {
            plotDirectory <- "/tmp/FederatedPs-D"
            dir.create(plotDirectory, showWarnings = FALSE)
            CohortMethod::plotPs(population, scale = "propensity", showCountsLabel = FALSE,
                showAucLabel = FALSE, fileName = file.path(plotDirectory, paste0(state$name, "-", method, "-ps.pdf")))
            CohortMethod::plotCovariateBalanceScatterPlot(balance,
                fileName = file.path(plotDirectory, paste0(state$name, "-", method, "-balance.pdf")))
        }
        if (!setequal(balance$covariateId, unique(long$covariateId))) {
            stop("Balance must use all original site covariates")
        }
        for (stage in c("before", "after")) {
            selected <- if (stage == "before") population else after
            observed <- balance$covariateId %in% unique(long$covariateId[long$rowId %in% selected$rowId])
            for (group in c(0, 1)) {
                rows <- selected$rowId[selected$treatment == group]
                means <- vapply(balance$covariateId, function(id) {
                    sum(long$covariateValue[long$covariateId == id & long$rowId %in% rows]) / length(rows)
                }, 0.0)
                column <- paste0(stage, "MatchingMean", if (group == 1) "Target" else "Comparator")
                if (!identical(is.na(balance[[column]]), !observed)) stop("Undefined balance means changed")
                .checkPsAgreement(balance[[column]][observed], means[observed])
                meanError <- max(meanError, abs(balance[[column]][observed] - means[observed]))
            }
        }
        matched[[method]] <- after
        summaries[[method]] <- data.frame(site = state$name, method = method,
            targetBefore = sum(population$treatment == 1), comparatorBefore = sum(population$treatment == 0),
            targetAfter = sum(after$treatment == 1), comparatorAfter = sum(after$treatment == 0),
            targetRetention = sum(after$treatment == 1) / sum(population$treatment == 1),
            comparatorRetention = sum(after$treatment == 0) / sum(population$treatment == 0),
            balanceFeatures = nrow(balance), undefinedSmd = sum(!is.finite(balance$afterMatchingStdDiff)),
            maxAbsSmdBefore = max(abs(balance$beforeMatchingStdDiff), na.rm = TRUE),
            maxAbsSmdAfter = max(abs(balance$afterMatchingStdDiff), na.rm = TRUE))
    }
    # Pair identifiers remain here; only the equality result is disclosed.
    pairs <- lapply(matched[c("pooled", "remote")], function(population) {
        sort(vapply(split(population$rowId, population$stratumId),
            function(rows) paste(sort(rows), collapse = ":"), ""), method = "radix")
    })
    state$population <- populations$remote
    state$matched <- matched
    state$evaluation <- list(summary = do.call(rbind, summaries), rawPsErrors = errors,
        balanceMeanError = meanError, pooledRemotePairsEqual = identical(pairs[[1]], pairs[[2]]),
        seconds = proc.time()[["elapsed"]] - started)
    if (identical(evaluation$type, "D")) state$evaluation$errors <- state$dErrors
    state$evaluationDone <- TRUE
    state
}

.psEvaluationError <- function(actual, expected, tolerance) {
    if (length(actual) != length(expected) || any(!is.finite(c(actual, expected)))) stop("Invalid synthetic reference")
    difference <- abs(actual - expected)
    ratio <- difference / (tolerance + tolerance * pmax(abs(actual), abs(expected)))
    if (any(ratio > 1)) stop("D result differs from the independent synthetic reference")
    c(absolute = max(c(0, difference)), toleranceRatio = max(c(0, ratio)))
}

#' @rdname psSiteComputation
#' @export
getPsSiteEvaluationDS <- function(state, runId, step) {
    .checkPsSiteStep(state, runId, step)
    if (!isTRUE(state$evaluationDone)) stop("Site evaluation is not complete")
    if (isTRUE(state$privateData)) {
        return(list(site = state$name, runId = runId, step = state$step,
            evaluation = state$evaluation[c("numericalComparison", "nativeCache", "stateUnchanged",
                "matchingStatus", "balanceStatus", "plotStatus", "savedPrivately")]))
    }
    list(site = state$name, runId = runId, step = state$step, evaluation = state$evaluation)
}

# Real results stay on the worker; the aggregate endpoint returns statuses only.
.evaluatePsCdmSite <- function(state, input, model, fit, runId, step) {
    partial <- identical(model$returnFlag, "MAX_ITERATIONS") &&
        identical(input$evaluation$pooledStatus, "MAX_ITERATIONS") &&
        isTRUE(model$iterations == input$evaluation$pooledIterations)
    if (!.psCdmInput(input) || !identical(input$name, state$name) ||
        !(identical(model$returnFlag, "SUCCESS") || partial) ||
        !identical(input$settings, state$specification$settings) ||
        !is.list(input$evaluation) || !identical(input$evaluation$type, "cdm")) {
        stop("Private evaluation requires the corresponding successful CDM fit")
    }
    directory <- "/opt/federatedps/private/results"
    if (!dir.exists(directory) || !identical(normalizePath(directory), directory) ||
        as.character(file.info(directory)$mode) != "700") stop("Private result directory is not configured")
    destination <- file.path(directory, paste0(runId, "-evaluation.rds"))
    if (file.exists(destination)) stop("Private evaluation already exists")
    before <- getPsSiteStatusDS(state, runId, step)
    ps <- stats::predict(fit)
    if (!identical(names(ps), rownames(state$site$x))) stop("Native prediction row mapping differs")
    eta <- as.numeric(state$site$x %*% model$coefficients[-1L]) + model$coefficients[[1L]]
    reference <- input$evaluation
    if (!identical(names(reference$pooledPs), names(ps)) ||
        !identical(reference$covariateIds, state$coordinates[-1L]) ||
        !identical(names(input$scales), names(reference$scales))) stop("Private reference row or feature mapping differs")
    errors <- list(rawPs = .psEvaluationError(ps, reference$pooledPs, 1e-7),
        nativeCache = .psEvaluationError(ps, stats::plogis(eta), 1e-7),
        linearPredictor = .psEvaluationError(eta, reference$pooledEta, 1e-7),
        scale = .psEvaluationError(input$scales, reference$scales, 1e-12))
    if (!identical(before, getPsSiteStatusDS(state, runId, step)) ||
        !identical(ps, stats::predict(Cyclops::getCyclopsCoordinateFit(state$ccd)))) stop("Private evaluation changed native state")
    if (partial) {
        state$evaluation <- list(numericalComparison = "passed_partial_same_sweep", nativeCache = "passed",
            stateUnchanged = "passed", matchingStatus = c(remote = "not_run_nonconverged"),
            balanceStatus = c(remote = "not_run_nonconverged"), plotStatus = c(remote = "not_run_nonconverged"),
            savedPrivately = TRUE)
        saveRDS(list(status = state$evaluation, errors = errors, model = model,
            diagnosticPrediction = ps, diagnosticLinearPredictor = eta), destination)
        Sys.chmod(destination, "0600")
        state$evaluationDone <- TRUE
        return(state)
    }
    if (!identical(reference$pooledStatus, "SUCCESS") || !identical(reference$localStatus, "SUCCESS")) {
        stop("Final comparison requires successful independent reference fits")
    }
    populations <- reference$populations
    original <- state$site$population
    if (!identical(names(populations), c("local", "pooled"))) stop("Missing private reference methods")
    for (population in populations) {
        if (!identical(population[names(original)], original)) stop("Private reference population mapping differs")
    }
    populations$remote <- .joinPsPopulation(original, ps)
    matched <- balances <- summaries <- list()
    matchingStatus <- balanceStatus <- plotStatus <- stats::setNames(rep("not_run", 3), names(populations))
    matching <- do.call(CohortMethod::createMatchOnPsArgs, reference$matching)
    balanceArgs <- do.call(CohortMethod::createComputeCovariateBalanceArgs, reference$balance)
    for (method in names(populations)) {
        population <- populations[[method]][order(populations[[method]]$rowId), ]
        # Record OHDSI downstream failures separately. Never turn failure into
        # an invented population/table or reinterpret a partial fit as SUCCESS.
        attempt <- tryCatch({
            set.seed(reference$seed)
            after <- CohortMethod::matchOnPs(population, matching)
            set.seed(reference$seed)
            repeated <- CohortMethod::matchOnPs(population, matching)
            if (!identical(after, repeated) || !all(after$rowId %in% original$rowId) ||
                !identical(after$propensityScore, population$propensityScore[match(after$rowId, population$rowId)])) stop("Matching row or reproducibility failure")
            after
        }, error = function(e) e)
        if (inherits(attempt, "error")) {
            matchingStatus[[method]] <- "failed"
            summaries[[method]] <- list(matchingError = conditionMessage(attempt))
            next
        }
        after <- attempt; matched[[method]] <- after
        matchingStatus[[method]] <- if (nrow(after)) "completed" else "completed_empty"
        summaries[[method]] <- list(before = table(population$treatment), after = table(after$treatment))
        if (length(unique(after$treatment)) != 2L) {
            balanceStatus[[method]] <- "not_run_no_matched_groups"
            next
        }
        balance <- tryCatch(CohortMethod::computeCovariateBalance(after, state$site$cohortMethodData, balanceArgs), error = function(e) e)
        if (inherits(balance, "error")) {
            balanceStatus[[method]] <- "failed"
            summaries[[method]]$balanceError <- conditionMessage(balance)
            next
        }
        if (!setequal(balance$covariateId, unique(input$site$covariates$covariateId))) stop("Balance omitted original covariates")
        balances[[method]] <- balance; balanceStatus[[method]] <- "completed"
        plotting <- tryCatch({
            CohortMethod::plotPs(population, scale = "propensity", showCountsLabel = FALSE, showAucLabel = FALSE,
                fileName = file.path(directory, paste0(runId, "-", method, "-ps.pdf")))
            CohortMethod::plotCovariateBalanceScatterPlot(balance,
                fileName = file.path(directory, paste0(runId, "-", method, "-balance.pdf")))
            TRUE
        }, error = function(e) e)
        plotStatus[[method]] <- if (isTRUE(plotting)) "completed" else "failed"
        if (inherits(plotting, "error")) summaries[[method]]$plotError <- conditionMessage(plotting)
    }
    state$population <- populations$remote; state$matched <- matched
    state$evaluation <- list(numericalComparison = "passed", nativeCache = "passed", stateUnchanged = "passed",
        matchingStatus = matchingStatus, balanceStatus = balanceStatus, plotStatus = plotStatus, savedPrivately = TRUE)
    saveRDS(list(status = state$evaluation, errors = errors, model = model,
        populations = populations, matched = matched, balances = balances, summaries = summaries), destination)
    Sys.chmod(list.files(directory, full.names = TRUE), "0600")
    state$evaluationDone <- TRUE
    state
}
