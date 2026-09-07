# Reuse the B1 fixture definitions without repeating its fitting tests.
c1Fixture <- function() {
    previous <- Sys.getenv("FEDERATEDPS_SETUP_ONLY", unset = NA_character_)
    on.exit(if (is.na(previous)) Sys.unsetenv("FEDERATEDPS_SETUP_ONLY") else
        Sys.setenv(FEDERATEDPS_SETUP_ONLY = previous), add = TRUE)
    Sys.setenv(FEDERATEDPS_SETUP_ONLY = "true")
    definitions <- new.env(parent = environment())
    sys.source(testthat::test_path("test-federatedPs.R"), envir = definitions)
    fixture <- definitions$b1Fixture()
    settings <- definitions$b1Settings
    initial <- stats::setNames(rep(settings$initial, 8L),
        c("(Intercept)", as.character(fixture$covariateIds[fixture$covariateIds != 4001])))
    lapply(names(fixture$sites), function(name) list(synthetic = TRUE, name = name,
        site = fixture$sites[[name]], covariateIds = fixture$covariateIds,
        scales = fixture$scales, excludedIds = 4001,
        diagnosticSettings = list(matching = settings$matching, balance = settings$balance),
        settings = list(priorVariance = settings$variance, control = settings$control,
                        startingCoefficients = initial)))
}

test_that("site setup preserves the common mask and native updates stay isolated", {
    inputs <- c1Fixture()
    states <- lapply(inputs, initializePsSiteDS, runId = "boundary")
    on.exit(for (state in states) Andromeda::close(state$site$cohortMethodData), add = TRUE)
    expect_identical(colnames(states[[1]]$site$x), colnames(states[[2]]$site$x))
    expect_true(all(states[[1]]$site$x[, "2001"] == 0))
    expect_true(any(states[[2]]$site$x[, "2001"] != 0))
    expect_false("4001" %in% colnames(states[[1]]$site$x))
    status <- lapply(states, getPsSiteStatusDS, runId = "boundary", step = 0)
    expect_identical(status[[1L]]$process$cyclopsNative, getLoadedDLLs()[["Cyclops"]][["path"]])
    expect_identical(status[[1]]$specification, status[[2]]$specification)
    likelihood <- sum(vapply(status, function(x) x$logLikelihood, 0.0))
    for (state in states) checkPsSiteConvergenceDS(state, "boundary", 0, likelihood)
    for (step in 0:1) {
        coordinate <- step + 1L
        statistics <- lapply(states, getPsSiteStatisticsDS, runId = "boundary",
            step = step, covariate = coordinate)
        expect_identical(statistics[[1]],
            getPsSiteStatisticsDS(states[[1]], "boundary", step, coordinate))
        total <- Reduce(`+`, lapply(statistics, function(x) x$statistics[1:2]))
        updatePsSiteDS(states[[1]], "boundary", step, coordinate, total[[1]], total[[2]])
        expect_identical(statistics[[2]],
            getPsSiteStatisticsDS(states[[2]], "boundary", step, coordinate))
        updatePsSiteDS(states[[2]], "boundary", step, coordinate, total[[1]], total[[2]])
        updates <- lapply(states, getPsSiteStatusDS, runId = "boundary", step = step + 1)
        expect_equal(updates[[1]]$update, updates[[2]]$update, tolerance = 0)
        expect_identical(updates[[1]]$initializations, 1L)
        expect_false(any(c("ccd", "siteData", "population", "rowId", "propensityScore") %in%
            names(updates[[1]])))
    }
    expect_error(updatePsSiteDS(states[[1]], "boundary", 1, 2, 1, 1),
        "stale, duplicate")
    expect_error(getPsSiteStatusDS(states[[1]], "boundary", 2), "failed")
    expect_equal(getPsSiteStatusDS(states[[2]], "boundary", 2)$step, 2)
})

test_that("site boundaries reject invalid agreed inputs and nonfinite updates", {
    input <- c1Fixture()[[1]]
    bad <- input
    bad$excludedIds <- c(4001, 7001)
    expect_error(initializePsSiteDS(bad, "invalid"), "zero-column mask")
    bad <- input
    bad$scales <- rev(bad$scales)
    expect_error(initializePsSiteDS(bad, "invalid"), "feature order")
    state <- initializePsSiteDS(input, "nonfinite")
    on.exit(Andromeda::close(state$site$cohortMethodData), add = TRUE)
    status <- getPsSiteStatusDS(state, "nonfinite", 0)
    expect_error(evaluatePsSiteDS(state, input, "nonfinite", 0), "completed")
    expect_error(getPsSiteEvaluationDS(state, "nonfinite", 0), "not complete")
    checkPsSiteConvergenceDS(state, "nonfinite", 0, status$logLikelihood)
    expect_error(getPsSiteStatisticsDS(state, "other-run", 0, 1), "site/run/step")
    expect_error(getPsSiteStatisticsDS(state, "nonfinite", 0, 2), "[Cc]oordinate")
    expect_error(getPsSiteStatisticsDS(state, "nonfinite", 0, 1.5), "[Cc]oordinate")
    expect_error(updatePsSiteDS(state, "nonfinite", 0, 1, Inf, 1), "finite")
    expect_error(getPsSiteStatusDS(state, "nonfinite", 0), "failed")
    expect_error(checkPsPrecisionDS(0, -1, NA_real_, 1/3, 1 + 2^-52), "finite")
    values <- c(0, -0.12345678901234567, 2^-48, pi, 1 + 2^-52)
    expect_identical(do.call(checkPsPrecisionDS, as.list(values)), values)
})

test_that("the remote entry point rejects invalid connections and symbols before I/O", {
    expect_error(fitPsDataShield(NULL, "input", "run", returnPartial = NA), "returnPartial")
    expect_error(fitPsDataShield(list(site1 = NULL), "input", "run"), "Exactly two")
    expect_error(fitPsDataShield(stats::setNames(list(NULL, NULL), c("same", "same")),
        "input", "run"), "uniquely named")
    expect_error(fitPsDataShield(list(site1 = NULL, site2 = NULL), "input;code", "run"),
        "Invalid input symbol")
    expect_error(fitPsDataShield(list(site1 = NULL, site2 = NULL), "input", "run()"),
        "run identifier")
})

test_that("MAX_ITERATIONS is a finite read-only termination, not a failed fit", {
    input <- c1Fixture()[[2L]] # Every common feature is observed on this site.
    input$settings$control$maxIterations <- 1L
    state <- initializePsSiteDS(input, "limit")
    on.exit(Andromeda::close(state$site$cohortMethodData), add = TRUE)
    before <- getPsSiteStatusDS(state, "limit", 0)
    checkPsSiteConvergenceDS(state, "limit", 0, before$logLikelihood)
    expect_identical(state$step, 0L)
    expect_equal(Cyclops::getCyclopsCoordinateFit(state$ccd)$iterations, 0)
    for (j in seq_along(state$coordinates)) {
        values <- getPsSiteStatisticsDS(state, "limit", j - 1L, j)$statistics
        updatePsSiteDS(state, "limit", j - 1L, j, values[[1L]], values[[2L]])
    }
    step <- state$step
    snapshot <- Cyclops::getCyclopsCoordinateFit(state$ccd)
    checkPsSiteConvergenceDS(state, "limit", step, snapshot$log_likelihood)
    snapshot <- Cyclops::getCyclopsCoordinateFit(state$ccd)
    prediction <- stats::predict(snapshot)
    terminal <- getPsSiteStatusDS(state, "limit", step)
    expect_false(state$failed)
    expect_identical(terminal$model$returnFlag, "MAX_ITERATIONS")
    expect_identical(terminal$model$converged, FALSE)
    expect_equal(terminal$model$iterations, 1)
    expect_equal(step, length(state$coordinates))
    expect_error(stats::coef(snapshot), "converg")
    expect_identical(terminal$model$coefficients, stats::coef(snapshot, ignoreConvergence = TRUE))
    for (i in 1:3) {
        expect_identical(getPsSiteStatusDS(state, "limit", step), terminal)
        expect_identical(stats::predict(Cyclops::getCyclopsCoordinateFit(state$ccd)), prediction)
    }
    expect_error(getPsSiteStatusDS(state, "wrong", step), "site/run/step")
    expect_error(getPsSiteStatusDS(state, "limit", step - 1L), "site/run/step")
    expect_error(evaluatePsSiteDS(state, input, "limit", step), "Matching requires.*SUCCESS")
    expect_null(state$matched)
    input$evaluation <- list(type = "sweep", step = step, rawPs = prediction,
        linearPredictor = stats::setNames(stats::qlogis(prediction), names(prediction)))
    evaluatePsSiteDS(state, input, "limit", step)
    evaluation <- getPsSiteEvaluationDS(state, "limit", step)$evaluation
    expect_true(all(evaluation$errors["toleranceRatio", ] <= 1))
    expect_true(evaluation$statusUnchanged)
    expect_true(evaluation$nativePredictionUnchanged)
    expect_false(evaluation$matchingPerformed)
    expect_null(state$matched)
    expect_identical(getPsSiteStatusDS(state, "limit", step), terminal)
    expect_error(updatePsSiteDS(state, "limit", step, 1, 0, 1), "ready for an update")
    expect_identical(stats::predict(Cyclops::getCyclopsCoordinateFit(state$ccd)), prediction)
    expect_error(getPsSiteStatusDS(state, "limit", step), "failed")
})

test_that("returnPartial never converts invalid remote replies into a model", {
    for (package in c("DSI", "DSOpal", "opalr")) testthat::skip_if_not_installed(package)
    # Mock only public I/O for deterministic response failures. The coordinator
    # under test is the production function, not a second learning loop.
    loadNamespace("DSOpal")
    connections <- stats::setNames(lapply(1:2, function(i) methods::new("OpalConnection")),
        c("site1", "site2"))
    inputs <- c1Fixture()
    for (fault in c("missing", "stale", "nonfinite", "workerLoss", "partialSweep")) {
        local({
            aggregates <- 0L
            testthat::local_mocked_bindings(opal.session_exists = function(...) TRUE, .package = "opalr")
            testthat::local_mocked_bindings(
                datashield.symbols = function(...) list(site1 = character(), site2 = character()),
                datashield.assign.expr = function(..., async) {
                    expression <- list(...)[[3L]]
                    if (fault == "workerLoss" && startsWith(expression, "updatePsSiteDS")) {
                        stop("worker session lost after site1 update")
                    }
                    invisible(NULL)
                },
                datashield.aggregate = function(..., async) {
                    aggregates <<- aggregates + 1L
                    replies <- lapply(seq_along(connections), function(i) {
                        value <- list(site = names(connections)[[i]], runId = "failure", step = 0L,
                            initializations = 1L, done = FALSE, logLikelihood = -10, logPrior = 0,
                            specification = list(settings = inputs[[1L]]$settings),
                            process = list(host = paste0("test-worker", i), pid = i))
                        if (aggregates >= 3L) value$statistics <-
                            c(gradient = 0, curvature = 1, coefficient = 0, bound = 2)
                        if (aggregates == 2L && fault == "partialSweep") value$done <- i == 1L
                        if (aggregates >= 3L && i == 2L && fault == "stale") value$step <- 1L
                        if (aggregates >= 3L && i == 2L && fault == "nonfinite") value$statistics[[1L]] <- Inf
                        value
                    })
                    names(replies) <- names(connections)
                    if (aggregates >= 3L && fault == "missing") replies <- replies[1L]
                    replies
                }, .package = "DSI")
            expected <- switch(fault, missing = "Missing or duplicate", stale = "Stale or mismatched",
                nonfinite = "Invalid coordinate statistics", workerLoss = "worker session lost",
                partialSweep = "convergence states disagree")
            expect_error(fitPsDataShield(connections, "input", "failure", returnPartial = TRUE), expected)
        })
    }
})

test_that("completed site evaluation preserves population metadata and returns only summaries", {
    inputs <- c1Fixture()
    siteNames <- vapply(inputs, function(x) x$name, "")
    prepared <- preparePsData(stats::setNames(lapply(inputs, function(x) x$site), siteNames),
        inputs[[1]]$covariateIds, inputs[[1]]$scales)
    on.exit(for (site in prepared$sites) Andromeda::close(site$cohortMethodData), add = TRUE)
    settings <- inputs[[1]]$settings
    results <- lapply(c("local", "pooled", "simulation"), function(method) {
        fitPs(prepared, method, settings$priorVariance,
            do.call(Cyclops::createControl, settings$control), settings$startingCoefficients)
    })
    names(results) <- c("local", "pooled", "simulation")
    states <- lapply(inputs, initializePsSiteDS, runId = "evaluation")
    on.exit(for (state in states) Andromeda::close(state$site$cohortMethodData), add = TRUE)
    step <- 0L
    repeat {
        status <- lapply(states, getPsSiteStatusDS, runId = "evaluation", step = step)
        likelihood <- sum(vapply(status, function(x) x$logLikelihood, 0.0))
        for (state in states) checkPsSiteConvergenceDS(state, "evaluation", step, likelihood)
        if (all(vapply(states, function(x) x$done, TRUE))) break
        for (j in seq_along(settings$startingCoefficients)) {
            values <- lapply(states, getPsSiteStatisticsDS, runId = "evaluation", step = step, covariate = j)
            total <- Reduce(`+`, lapply(values, function(x) x$statistics[1:2]))
            for (state in states) updatePsSiteDS(state, "evaluation", step, j, total[[1]], total[[2]])
            step <- step + 1L
        }
    }
    for (i in seq_along(states)) {
        input <- inputs[[i]]
        input$evaluation <- c(list(populations = lapply(results, function(x) x$populations[[input$name]])),
            input$diagnosticSettings)
        bad <- input
        attr(bad$evaluation$populations$pooled, "metaData") <- NULL
        expect_error(evaluatePsSiteDS(states[[i]], bad, "evaluation", step), "original population")
        evaluatePsSiteDS(states[[i]], input, "evaluation", step)
        value <- getPsSiteEvaluationDS(states[[i]], "evaluation", step)
        expect_identical(states[[i]]$population$rowId, input$site$population$rowId)
        expect_identical(attr(states[[i]]$population, "metaData"), attr(input$site$population, "metaData"))
        expect_identical(names(value), c("site", "runId", "step", "evaluation"))
        expect_setequal(names(value$evaluation), c("summary", "rawPsErrors", "balanceMeanError",
            "pooledRemotePairsEqual", "seconds"))
        expect_true(all(value$evaluation$rawPsErrors <= 1e-7))
        expect_equal(nrow(value$evaluation$summary), 4L)
        expect_error(evaluatePsSiteDS(states[[i]], input, "evaluation", step), "unevaluated")
    }
})


test_that("explicit CDM inputs preserve exact local identity without synthetic relabelling", {
    input <- c1Fixture()[[1L]]
    input$synthetic <- FALSE
    expect_error(initializePsSiteDS(input, "realguard"), "Invalid site")
    input$dataMode <- "cdm"
    input$site$metadata <- list(dataMode = "cdm")
    input$site$population$personId <- paste0("9007199254740993-", input$site$population$rowId)
    original <- input$site$population
    input$site$covariates$covariateValue <- abs(input$site$covariates$covariateValue)
    input$site$covariateRef$timeWindow <- "[-90,-1]"
    input$site$covariateRef$valueType <- ifelse(input$site$covariateRef$analysisId == 1, "binary", "continuous")
    input$site$covariateRef$isCollected <- TRUE
    prepared <- preparePsCvDS(input, folds = 0L, seed = 20260907L)
    on.exit(Andromeda::close(prepared$raw$cohortMethodData), add = TRUE)
    expect_identical(prepared$raw$population, original)
    expect_false(attr(prepared$raw$cohortMethodData, "metaData")$synthetic)
    expect_true(all(prepared$foldId == 0L))
    summary <- getPsPreprocessingDS(prepared, 0L)
    expect_identical(summary$validationN, 0)
    expect_identical(summary$n, as.numeric(nrow(original)))
    expect_identical(summary$nonzero[["2001"]], 0L)
    spec <- combinePsSummaries(stats::setNames(list(summary), input$name), 0.001)
    applied <- applyPsPreprocessingDS(prepared, 0L, spec$covariateIds, spec$scales)
    expect_identical(applied$preparedSite$population, original)
    expect_identical(rownames(applied$preparedSite$x), as.character(original$rowId[order(original$rowId)]))
    expect_error(getPsPreprocessingDS(prepared, 1L), "Invalid")
    bad <- input; bad$site$metadata$dataMode <- "synthetic"
    expect_error(preparePsCvDS(bad, 0L, 20260907L), "Invalid")
    previous <- Sys.getenv("FEDERATEDPS_DATA_MODE", unset = NA_character_)
    on.exit(if (is.na(previous)) Sys.unsetenv("FEDERATEDPS_DATA_MODE") else
        Sys.setenv(FEDERATEDPS_DATA_MODE = previous), add = TRUE)
    Sys.unsetenv("FEDERATEDPS_DATA_MODE")
    expect_error(loadPsCdmDS(), "not enabled")
    expect_error(loadPsCdmDS("arbitrary-file"), "unused argument")
})

test_that("private evaluation aggregate returns statuses, never saved patient results", {
    state <- new.env(parent = emptyenv())
    state$runId <- "private"; state$step <- 0L; state$failed <- FALSE
    state$name <- "site1"; state$privateData <- TRUE; state$evaluationDone <- TRUE
    state$evaluation <- list(numericalComparison = "passed", nativeCache = "passed",
        stateUnchanged = "passed", matchingStatus = "completed", balanceStatus = "completed",
        plotStatus = "completed", savedPrivately = TRUE,
        population = data.frame(rowId = 1, propensityScore = 0.5), coefficient = 2)
    result <- getPsSiteEvaluationDS(state, "private", 0L)
    expect_identical(names(result$evaluation), c("numericalComparison", "nativeCache", "stateUnchanged",
        "matchingStatus", "balanceStatus", "plotStatus", "savedPrivately"))
    expect_false(any(c("population", "coefficient") %in% names(result$evaluation)))
    expect_error(getPsSiteEvaluationDS(state, "other", 0L), "stale")
})


test_that("complete FE categorical rows are accepted without rewriting NULL metadata", {
    input <- c1Fixture()[[1L]]
    site <- input$site
    site$metadata <- list(dataMode = "cdm")
    site$analysisRef <- rbind(site$analysisRef, data.frame(analysisId = 99,
        analysisName = "DemographicsGender", domainId = "Demographics",
        isBinary = "Y", missingMeansZero = NA_character_))
    site$covariateRef <- rbind(site$covariateRef, data.frame(covariateId = c(99001, 99002),
        covariateName = c("category A", "category B"), analysisId = 99))
    extra <- data.frame(rowId = site$population$rowId,
        covariateId = rep(c(99001, 99002), length.out = nrow(site$population)), covariateValue = 1)
    site$covariates <- rbind(site$covariates, extra)
    ids <- c(input$covariateIds, 99001, 99002)
    scales <- stats::setNames(rep(1, length(ids)), as.character(ids))
    before <- site
    result <- .preparePsSites(list(site1 = site), ids, scales)
    on.exit(Andromeda::close(result$sites[[1L]]$cohortMethodData), add = TRUE)
    expect_identical(site, before)
    stored <- as.data.frame(dplyr::collect(result$sites[[1L]]$cohortMethodData$analysisRef))
    expect_true(is.na(stored$missingMeansZero[stored$analysisId == 99]))
    bad <- site
    bad$covariates <- bad$covariates[-nrow(bad$covariates), ]
    expect_error(.preparePsSites(list(site1 = bad), ids, scales), "Incomplete")
    bad <- site; bad$metadata <- NULL
    expect_error(.preparePsSites(list(site1 = bad), ids, scales), "Reference metadata")
})


test_that("FE binary histories retain original metadata and require collected event semantics", {
    input <- c1Fixture()[[1L]]
    site <- input$site
    site$metadata <- list(dataMode = "cdm", featureExtractionVersion = "3.14.0")
    site$analysisRef$analysisName[1L] <- "ConditionOccurrenceLongTerm"
    site$analysisRef$missingMeansZero[1L] <- NA_character_
    site$covariateRef$valueType <- ifelse(site$covariateRef$analysisId == 1, "binary", "continuous")
    site$covariateRef$isCollected <- TRUE
    original <- site
    prepared <- .preparePsSites(list(site1 = site), input$covariateIds, input$scales)
    on.exit(Andromeda::close(prepared$sites[[1L]]$cohortMethodData), add = TRUE)
    expect_identical(site, original)
    ref <- as.data.frame(dplyr::collect(prepared$sites[[1L]]$cohortMethodData$analysisRef))
    expect_true(is.na(ref$missingMeansZero[ref$analysisId == 1]))
    bad <- site; bad$covariateRef$isCollected[[1L]] <- FALSE
    expect_error(.preparePsSites(list(site1 = bad), input$covariateIds, input$scales), "collection coverage")
    bad <- site
    index <- which(bad$covariates$covariateId %in% bad$covariateRef$covariateId[bad$covariateRef$analysisId == 1])[[1L]]
    bad$covariates$covariateValue[[index]] <- 0.5
    expect_error(.preparePsSites(list(site1 = bad), input$covariateIds, input$scales), "binary values")
    bad <- site; bad$metadata <- NULL
    expect_error(.preparePsSites(list(site1 = bad), input$covariateIds, input$scales), "Reference metadata")
})
