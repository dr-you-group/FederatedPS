# Fixed D settings, independent of the unchanged B1/C1 expectations.
dBase <- new.env()
local({
    previous <- Sys.getenv("FEDERATEDPS_SETUP_ONLY", unset = NA_character_)
    on.exit(if (is.na(previous)) Sys.unsetenv("FEDERATEDPS_SETUP_ONLY") else
        Sys.setenv(FEDERATEDPS_SETUP_ONLY = previous))
    Sys.setenv(FEDERATEDPS_SETUP_ONLY = "true")
    sys.source(testthat::test_path("test-federatedPs.R"), dBase)
})
dSettings <- list(seed = 20260907L, folds = 2L, variances = c(0.1, 1),
    minFraction = 0.05, maxIterations = 200L,
    scaleTolerance = c(absolute = 1e-12, relative = 1e-12),
    fitTolerance = c(absolute = 1e-7, relative = 1e-7))

dFolds <- function(site) {
    set.seed(dSettings$seed)
    population <- site$population[order(site$population$rowId), ]
    assigned <- stats::setNames(integer(nrow(population)), as.character(population$rowId))
    for (group in 0:1) {
        rows <- which(population$treatment == group)
        assigned[rows[sample.int(length(rows))]] <- rep(1:2, length.out = length(rows))
    }
    assigned
}

dFixture <- function() {
    fixture <- dBase$b1Fixture()
    extraIds <- c(11001, 11002, 11003, 11004)
    fixture$covariateIds <- c(fixture$covariateIds, extraIds)
    fixture$scales <- NULL
    for (name in names(fixture$sites)) {
        site <- fixture$sites[[name]]
        site$covariates$covariateValue <- abs(site$covariates$covariateValue)
        rows <- sort(site$population$rowId)
        fold <- dFolds(site)
        available <- rows[-1L] # This population row has no covariate records.
        rare <- head(available, if (name == "site1") 6L else 4L)
        validationOnly <- available[fold[as.character(available)] == 1L]
        additions <- list(
            data.frame(rowId = rare, covariateId = 11001, covariateValue = 1),
            data.frame(rowId = validationOnly, covariateId = 11002, covariateValue = 1),
            data.frame(rowId = available, covariateId = 11003,
                covariateValue = ifelse(fold[as.character(available)] == 1L, 10, 2) *
                    if (name == "site1") 1 else 2),
            data.frame(rowId = available, covariateId = 11004,
                covariateValue = (seq_along(available) %% 4) * if (name == "site1") 1 else 2))
        site$covariates <- rbind(site$covariates, do.call(rbind, additions))
        site$covariates <- site$covariates[site$covariates$rowId != rows[1L] & site$covariates$covariateId != 4001, ]
        site$covariates <- rbind(site$covariates,
            data.frame(rowId = rows[2L], covariateId = 4001, covariateValue = 0))
        site$covariateRef <- rbind(site$covariateRef,
            data.frame(covariateId = extraIds, covariateName = paste("D feature", extraIds),
                analysisId = c(1, 1, 2, 2)))
        site$covariateRef$timeWindow <- "Fixed synthetic baseline"
        site$covariateRef$valueType <- ifelse(site$covariateRef$analysisId == 1, "binary", "continuous")
        site$covariateRef$valueType[site$covariateRef$covariateId == 11004] <- "count"
        site$covariateRef$isCollected <- TRUE
        if (name == "site2") site$covariateRef <- site$covariateRef[rev(seq_len(nrow(site$covariateRef))), ]
        rownames(site$covariates) <- rownames(site$covariateRef) <- NULL
        fixture$sites[[name]] <- site
    }
    fixture
}

dInputs <- function(fixture = dFixture()) {
    control <- dBase$b1Settings$control
    control$maxIterations <- dSettings$maxIterations
    lapply(names(fixture$sites), function(name) list(synthetic = TRUE, name = name,
        site = fixture$sites[[name]], covariateIds = fixture$covariateIds,
        settings = list(control = control))) |>
        stats::setNames(names(fixture$sites))
}

# Independent evaluator: pooled raw training rows determine counts and maxima;
# no production summary/mask/scaling helper is used. Only ordinary Cyclops fits.
# This same fixed-prior loop also handles the one-site local-only comparison.
dOracle <- function(fixture, inputOnly = FALSE) {
    ids <- fixture$covariateIds
    assignments <- lapply(fixture$sites, dFolds)
    control <- dBase$b1Settings$control
    control$maxIterations <- dSettings$maxIterations
    specifications <- transformed <- models <- populations <- list()
    losses <- list()
    for (fold in c(1L, 2L, 0L)) {
        training <- lapply(assignments, function(x) names(x)[fold == 0L | x != fold])
        n <- sum(lengths(training))
        longs <- lapply(names(training), function(name) {
            long <- fixture$sites[[name]]$covariates
            long[as.character(long$rowId) %in% training[[name]], ]
        })
        pooled <- do.call(rbind, longs)
        nonzero <- stats::setNames(vapply(ids, function(id) {
            sum(pooled$covariateId == id & pooled$covariateValue != 0)
        }, 0.0), as.character(ids))
        maximum <- stats::setNames(vapply(ids, function(id) {
            max(c(0, pooled$covariateValue[pooled$covariateId == id]))
        }, 0.0), as.character(ids))
        keep <- nonzero > 0 & nonzero / n >= dSettings$minFraction
        spec <- list(n = n, nonzero = nonzero, maximum = maximum, covariateIds = ids[keep],
            excludedIds = ids[!keep], scales = maximum[keep])
        specifications[[as.character(fold)]] <- spec
        matrices <- lapply(names(fixture$sites), function(name) {
            site <- fixture$sites[[name]]
            rows <- sort(site$population$rowId)
            long <- site$covariates[site$covariates$covariateId %in% ids[keep], ]
            x <- Matrix::sparseMatrix(i = match(long$rowId, rows), j = match(long$covariateId, ids[keep]),
                x = long$covariateValue / maximum[as.character(long$covariateId)],
                dims = c(length(rows), sum(keep)), dimnames = list(as.character(rows), as.character(ids[keep])))
            selected <- as.character(rows) %in% training[[name]]
            y <- stats::setNames(site$population$treatment[match(rows, site$population$rowId)], as.character(rows))
            list(train = x[selected, , drop = FALSE], valid = x[!selected, , drop = FALSE],
                trainY = y[selected], validY = y[!selected])
        })
        names(matrices) <- names(fixture$sites)
        transformed[[as.character(fold)]] <- matrices
        x <- do.call(rbind, lapply(matrices, function(x) x$train))
        y <- unlist(lapply(matrices, function(x) unname(x$trainY)), use.names = FALSE)
        rownames(x) <- unlist(lapply(names(matrices), function(name)
            paste0(nchar(name), ":", name, ":", rownames(matrices[[name]]$train))))
        if (inputOnly) return(list(x = x, y = stats::setNames(y, rownames(x)),
            initial = stats::setNames(rep(0, ncol(x) + 1L), c("(Intercept)", colnames(x))),
            control = control, variance = dSettings$variances[1L], specification = spec,
            matrices = matrices, folds = assignments, training = training))
        for (variance in if (fold == 0) selectedVariance else dSettings$variances) {
            data <- Cyclops::createCyclopsData(y ~ 1, data = data.frame(y = y, row.names = rownames(x)),
                sx = x, modelType = "lr", floatingPoint = 64)
            data$coefficientNames <- c("(Intercept)", colnames(x))
            fit <- Cyclops::fitCyclopsModel(data,
                prior = Cyclops::createPrior("laplace", variance = variance,
                    exclude = "(Intercept)", useCrossValidation = FALSE),
                control = do.call(Cyclops::createControl, control), startingCoefficients = rep(0, ncol(x) + 1L))
            if (!identical(fit$return_flag, "SUCCESS")) {
                stop(sprintf(paste0("D oracle incomplete: sites=%s fold=%d variance=%.17g nTrain=%d p=%d ",
                    "status=%s iterations=%d logLikelihood=%.17g logPrior=%.17g Cyclops=%s"),
                    paste(names(fixture$sites), collapse = ","), fold, variance, nrow(x), ncol(x),
                    fit$return_flag, fit$iterations, fit$log_likelihood, fit$log_prior, find.package("Cyclops")))
            }
            beta <- stats::coef(fit)
            key <- paste(fold, variance, sep = ":")
            models[[key]] <- list(coefficients = beta, objective = -(fit$log_likelihood + fit$log_prior),
                iterations = fit$iterations, returnFlag = fit$return_flag)
            for (name in names(matrices)) {
                subset <- matrices[[name]]
                if (fold != 0L) {
                    eta <- as.numeric(subset$valid %*% beta[-1L]) + beta[[1L]]
                    yValid <- subset$validY
                    loss <- sum(log1p(exp(-abs(eta))) + (1 - yValid) * pmax(eta, 0) + yValid * pmax(-eta, 0))
                    losses[[length(losses) + 1L]] <- data.frame(site = name, fold = fold,
                        priorVariance = variance, loss = loss, n = length(yValid))
                } else {
                    prediction <- stats::predict(fit)
                    keys <- paste0(nchar(name), ":", name, ":", rownames(subset$train))
                    population <- fixture$sites[[name]]$population
                    population$propensityScore <- unname(prediction[keys][match(as.character(population$rowId), rownames(subset$train))])
                    populations[[name]] <- population
                }
            }
        }
        if (fold == 2L) {
            validation <- do.call(rbind, losses)
            scores <- vapply(dSettings$variances, function(variance) {
                subset <- validation[validation$priorVariance == variance, ]
                sum(subset$loss) / sum(subset$n)
            }, 0.0)
            selectedVariance <- min(dSettings$variances[scores <= min(scores) + 1e-10])
        }
    }
    list(preprocessing = specifications, transformed = transformed, models = models,
        validation = validation, scores = scores, selectedVariance = selectedVariance,
        populations = populations, folds = assignments, cyclopsPath = find.package("Cyclops"))
}

# Independent diagnostic only; this never selects updates or changes Lange.
dKkt <- function(x, y, beta, variance) {
    eta <- as.numeric(x %*% beta[-1L]) + beta[[1L]]
    residualResponse <- stats::plogis(eta) - y
    gradient <- c(sum(residualResponse), as.numeric(Matrix::crossprod(x, residualResponse)))
    lambda <- c(0, rep(sqrt(2 / variance), ncol(x)))
    residual <- abs(gradient)
    penalized <- seq_along(beta) > 1L
    zero <- penalized & beta == 0
    nonzero <- penalized & beta != 0
    residual[zero] <- pmax(abs(gradient[zero]) - lambda[zero], 0)
    residual[nonzero] <- abs(gradient[nonzero] + lambda[nonzero] * sign(beta[nonzero]))
    allowance <- 1e-8 + 1e-8 * pmax(1, abs(gradient), lambda)
    likelihood <- -sum(log1p(exp(-abs(eta))) + ifelse(y == 1, pmax(-eta, 0), pmax(eta, 0)))
    logPrior <- sum(log(lambda[-1L] / 2) - lambda[-1L] * abs(beta[-1L]))
    stopifnot(all(is.finite(c(beta, gradient, residual, likelihood, logPrior))))
    list(eta = eta, ps = stats::plogis(eta), gradient = gradient, lambda = lambda,
        residual = residual, ratio = residual / allowance, logLikelihood = likelihood,
        logPrior = logPrior, objective = -(likelihood + logPrior))
}

if (!identical(Sys.getenv("FEDERATEDPS_SETUP_ONLY"), "true")) {
    test_that("training-only summaries and transformations equal an independent pooled calculation", {
        fixture <- dFixture()
        before <- fixture
        oracle <- dOracle(fixture)
        inputs <- dInputs(fixture)
        raw <- lapply(inputs, preparePsCvDS, folds = dSettings$folds, seed = dSettings$seed)
        on.exit(for (input in raw) Andromeda::close(input$raw$cohortMethodData), add = TRUE)
        for (fold in c(1L, 2L, 0L)) {
            summaries <- lapply(raw, getPsPreprocessingDS, fold = fold)
            spec <- combinePsSummaries(summaries, dSettings$minFraction)
            expected <- oracle$preprocessing[[as.character(fold)]]
            for (field in c("n", "nonzero", "covariateIds", "excludedIds")) expect_equal(spec[[field]], expected[[field]], tolerance = 0)
            dBase$b1Compare(spec$maximum, expected$maximum, dSettings$scaleTolerance)
            dBase$b1Compare(spec$scales, expected$scales, dSettings$scaleTolerance)
            transformed <- lapply(raw, applyPsPreprocessingDS, fold = fold,
                covariateIds = spec$covariateIds, scales = spec$scales)
            for (name in names(raw)) {
                expectedX <- oracle$transformed[[as.character(fold)]][[name]]
                expect_equal(transformed[[name]]$preparedSite$x, expectedX$train, tolerance = 1e-12)
                expect_equal(transformed[[name]]$validation$x, expectedX$valid, tolerance = 1e-12)
                expect_identical(raw[[name]]$foldId, unname(oracle$folds[[name]]))
                expect_equal(transformed[[name]]$preparedSite$y, expectedX$trainY, tolerance = 0)
                expect_identical(raw[[name]]$site$covariates, before$sites[[name]]$covariates)
            }
            expect_true("2001" %in% colnames(transformed$site1$preparedSite$x))
            expect_equal(Matrix::nnzero(transformed$site1$preparedSite$x[, "2001"]), 0)
            expect_true(4001 %in% spec$excludedIds)
            if (fold == 1L) {
                expect_true(11002 %in% spec$excludedIds)
                expect_equal(unname(spec$scales["11003"]), 4, tolerance = 0)
                expect_gt(max(transformed$site2$validation$x[, "11003"]), 1)
            }
        }
        full <- oracle$preprocessing[["0"]]
        expect_equal(full$n, 216)
        expect_equal(unname(full$nonzero["11001"]), 10)
        expect_true(11001 %in% full$excludedIds)
        # Exactly 1/20 is retained; zero is removed even at threshold zero.
        boundary <- getPsPreprocessingDS(raw$site1, 0)
        boundary$n <- boundary$totalN <- 20
        boundary$nonzero[] <- 0
        boundary$maximum[] <- 0
        boundary$nonzero[1L] <- boundary$maximum[1L] <- 1
        selected <- combinePsSummaries(list(site1 = boundary), 0.05)
        expect_identical(selected$covariateIds, boundary$covariateIds[1L])
        expect_error(combinePsSummaries(list(site1 = boundary), 0.0500001), "No feature remains")
        bad <- lapply(raw, getPsPreprocessingDS, fold = 1)
        bad$site2$reference$covariateRef$timeWindow[1L] <- "Different window"
        expect_error(combinePsSummaries(bad), "meanings")
        bad <- inputs$site1
        bad$site$covariates$covariateValue[1L] <- -1
        expect_error(preparePsCvDS(bad, 2, dSettings$seed), "nonnegative")
        bad$site$covariates$covariateValue[1L] <- NA_real_
        expect_error(preparePsCvDS(bad, 2, dSettings$seed), "finite numeric")
        bad <- inputs$site1
        bad$site$covariates <- rbind(bad$site$covariates, bad$site$covariates[1L, ])
        expect_error(preparePsCvDS(bad, 2, dSettings$seed), "Duplicate")
        bad <- inputs$site1
        bad$site$covariateRef$isCollected[1L] <- FALSE
        expect_error(preparePsCvDS(bad, 2, dSettings$seed), "collection coverage")
        expect_identical(fixture, before)
    })

    test_that("validation loss is stable at finite extreme logits without clipping", {
        loss <- getFromNamespace(".psValidationLoss", "FederatedPs")
        expect_equal(loss(c(1000, -1000), c(1, 0)), 0, tolerance = 0)
        expect_equal(loss(c(1000, -1000), c(0, 1)), 2000, tolerance = 0)
        expect_equal(loss(c(1e300, -1e300), c(1, 0)), 0, tolerance = 0)
        expect_equal(loss(c(0, 0), c(0, 1)), 2 * log(2), tolerance = 1e-15)
        expect_error(loss(c(Inf, 0), c(1, 0)), "Invalid")
    })

    test_that("the corrected native classification accepts the verified local initial optimum", {
        fixture <- dFixture()
        fixture$sites <- fixture$sites["site1"]
        input <- dOracle(fixture, inputOnly = TRUE)
        before <- dKkt(input$x, input$y, input$initial, input$variance)
        expect_equal(c(sum(input$y), sum(input$y == 0)), c(30, 30))
        expect_equal(before$residual, rep(0, length(input$initial)), tolerance = 0)
        oracle <- dOracle(fixture)
        first <- oracle$models[["1:0.1"]]
        expect_identical(first$returnFlag, "SUCCESS")
        expect_equal(first$iterations, 1)
        expect_identical(first$coefficients, input$initial)
        after <- dKkt(input$x, input$y, first$coefficients, input$variance)
        expect_true(all(after$ratio <= 1))
        dBase$b1Compare(first$objective, after$objective)
        expect_true(all(vapply(oracle$models, function(x) x$returnFlag == "SUCCESS", TRUE)))
        # U's original POOR_BLR_STEP is retained by the separate diagnostic run;
        # it is never consumed as a successful CV candidate.
    })

    test_that("existing simulation fits the independently preprocessed folds and final model", {
        fixture <- dFixture()
        oracle <- dOracle(fixture)
        raw <- lapply(dInputs(fixture), preparePsCvDS, folds = 2L, seed = dSettings$seed)
        on.exit(for (input in raw) Andromeda::close(input$raw$cohortMethodData), add = TRUE)
        loss <- getFromNamespace(".psValidationLoss", "FederatedPs")
        rowMap <- getFromNamespace(".psRowMap", "FederatedPs")
        for (fold in c(1L, 2L, 0L)) {
            spec <- combinePsSummaries(lapply(raw, getPsPreprocessingDS, fold = fold), dSettings$minFraction)
            transformed <- lapply(raw, applyPsPreprocessingDS, fold = fold,
                covariateIds = spec$covariateIds, scales = spec$scales)
            sites <- lapply(transformed, function(x) x$preparedSite)
            prepared <- list(sites = sites, covariateIds = spec$covariateIds,
                excludedIds = spec$excludedIds, rowMap = rowMap(sites))
            for (variance in if (fold == 0L) oracle$selectedVariance else dSettings$variances) {
                fitted <- fitPs(prepared, "simulation", variance,
                    do.call(Cyclops::createControl, raw[[1L]]$settings$control),
                    transformed[[1L]]$settings$startingCoefficients)
                expected <- oracle$models[[paste(fold, variance, sep = ":")]]
                dBase$b1Compare(fitted$models$global$objective, expected$objective)
                for (name in names(sites)) {
                    if (fold == 0L) {
                        expect_identical(fitted$populations[[name]]$rowId, fixture$sites[[name]]$population$rowId)
                        dBase$b1Compare(fitted$populations[[name]]$propensityScore, oracle$populations[[name]]$propensityScore)
                    } else {
                        valid <- transformed[[name]]$validation
                        beta <- fitted$models$global$coefficients
                        actual <- loss(as.numeric(valid$x %*% beta[-1L]) + beta[[1L]], valid$y)
                        expectedLoss <- oracle$validation[oracle$validation$site == name &
                            oracle$validation$fold == fold & oracle$validation$priorVariance == variance, "loss"]
                        dBase$b1Compare(actual, expectedLoss)
                    }
                }
            }
        }
        input <- setPsPriorDS(transformed$site1, oracle$selectedVariance)
        a <- initializePsSiteDS(input, "freshA")
        b <- initializePsSiteDS(input, "freshB")
        expect_false(identical(a$ccd, b$ccd))
        expect_equal(getPsSiteStatusDS(a, "freshA", 0)$iterations, 0)
        expect_identical(input$preparedSite$x, transformed$site1$preparedSite$x)
    })

    test_that("CV calls the strict existing fit and never selects after an incomplete fold", {
        skip_if_not_installed("DSI")
        skip_if_not_installed("DSOpal")
        loadNamespace("DSOpal")
        fixture <- dFixture()
        oracle <- dOracle(fixture)
        raw <- lapply(dInputs(fixture), preparePsCvDS, folds = 2L, seed = dSettings$seed)
        on.exit(for (input in raw) Andromeda::close(input$raw$cohortMethodData), add = TRUE)
        connections <- list(site1 = methods::new("OpalConnection"), site2 = methods::new("OpalConnection"))
        for (fault in c("none", "tie", "limit", "badCount")) local({
            calls <- list()
            identity <- NULL
            testthat::local_mocked_bindings(
                datashield.symbols = function(...) list(site1 = character(), site2 = character()),
                datashield.assign.expr = function(...) invisible(NULL),
                datashield.aggregate = function(conns, expr, ...) {
                    if (startsWith(expr, "getPsPreprocessingDS")) {
                        fold <- as.integer(sub(".*[,] ([0-9]+)[)]$", "\\1", expr))
                        return(lapply(raw, getPsPreprocessingDS, fold = fold))
                    }
                    rows <- oracle$validation[oracle$validation$fold == identity$fold &
                        oracle$validation$priorVariance == identity$variance, ]
                    result <- lapply(names(raw), function(name) {
                        selected <- rows[rows$site == name, ]
                        list(site = name, runId = identity$run, step = 10L,
                            fold = identity$fold, loss = if (fault == "tie") selected$n / 2 else selected$loss,
                            n = selected$n + if (fault == "badCount") 1 else 0)
                    })
                    stats::setNames(result, names(raw))
                }, .package = "DSI")
            testthat::local_mocked_bindings(fitPsDataShield = function(connections, inputSymbol, runId, returnPartial) {
                expect_identical(returnPartial, FALSE)
                fold <- as.integer(sub(".*f([0-9]+)v[0-9]+$", "\\1", runId))
                index <- as.integer(sub(".*v([0-9]+)$", "\\1", runId))
                variance <- dSettings$variances[index]
                identity <<- list(fold = fold, variance = variance, run = runId)
                calls[[length(calls) + 1L]] <<- runId
                if (fault == "limit") stop("Cyclops did not converge: MAX_ITERATIONS")
                model <- oracle$models[[paste(fold, variance, sep = ":")]]
                # A tie selects the smaller candidate; its final model is only
                # a stub here. Native fitting is tested separately above.
                if (is.null(model)) model <- tail(oracle$models, 1L)[[1L]]
                list(model = model, runId = runId, stateSymbol = paste0("ps_", runId), step = 10L)
            }, .package = "FederatedPs")
            if (fault %in% c("limit", "badCount")) {
                expect_error(fitPsDataShieldCv(connections, "input", "testD"),
                    if (fault == "limit") "MAX_ITERATIONS" else "validation loss or count")
                expect_length(calls, 1L)
            } else {
                result <- fitPsDataShieldCv(connections, "input", "testD")
                expect_equal(result$selectedVariance, if (fault == "tie") 0.1 else oracle$selectedVariance)
                expect_length(calls, 5L)
                expect_equal(anyDuplicated(unlist(calls)), 0L)
            }
        })
    })
}
