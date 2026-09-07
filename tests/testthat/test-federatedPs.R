# Fixed before running any fit. These are test settings, not a study protocol.
b1Settings <- list(seed = 20260907L, sizes = c(site1 = 120L, site2 = 96L),
    covariateIds = c(7001, 1001, 9001, 3001, 5001, 2001, 8001, 4001),
    scales = c(1, 2, 1, 1, 1, 1, 0.5, 1), variance = 1, initial = 0,
    control = list(convergenceType = "lange", tolerance = 1e-12,
        maxIterations = 5000L, initialBound = 2, algorithm = "ccd", threads = 1,
        useKKTSwindle = FALSE, noiseLevel = "silent", seed = 20260907L),
    matching = list(caliper = 0.2, caliperScale = "standardized logit",
        maxRatio = 1, allowReverseMatch = FALSE),
    balance = list(maxCohortSize = 10000, alpha = NULL),
    tolerance = c(absolute = 1e-7, relative = 1e-7),
    balanceTolerance = c(absolute = 1e-10, relative = 1e-10))

b1Fixture <- function() {
    set.seed(b1Settings$seed)
    ids <- b1Settings$covariateIds
    sites <- lapply(names(b1Settings$sizes), function(name) {
        n <- b1Settings$sizes[[name]]
        rows <- 1000 + 17 * seq_len(n) # Intentionally overlaps across sites.
        covariates <- vector("list", 8L)
        eta <- rep(-0.3, n)
        for (j in 1:7) {
            value <- rbinom(n, 1L, 0.35)
            if (j == 7L) value <- value * runif(n, -1, 2)
            if (j == 6L && name == "site1") value[] <- 0
            if (j == 1L) eta <- eta + 1.1 * value
            if (j == 2L) eta <- eta - 0.9 * value
            if (j == 7L) eta <- eta + 0.8 * value
            covariates[[j]] <- data.frame(rowId = rows[value != 0],
                covariateId = rep(ids[j], sum(value != 0)), covariateValue = value[value != 0])
        }
        # An explicit zero remains in the original diagnostic table.
        covariates[[8L]] <- data.frame(rowId = rows[1L], covariateId = ids[8L], covariateValue = 0)
        covariates <- do.call(rbind, covariates)
        covariates <- covariates[sample.int(nrow(covariates)), ]
        rownames(covariates) <- NULL
        population <- data.frame(rowId = rows, personSeqId = rows + 10000,
            treatment = as.numeric(rbinom(n, 1L, plogis(eta))),
            inputLabel = paste0("synthetic-", seq_len(n)))
        population <- population[sample.int(n), ]
        rownames(population) <- NULL
        attr(population, "metaData") <- list(synthetic = TRUE, site = name,
            attrition = data.frame(description = "Synthetic input",
                targetPersons = sum(population$treatment == 1),
                comparatorPersons = sum(population$treatment == 0),
                targetExposures = sum(population$treatment == 1),
                comparatorExposures = sum(population$treatment == 0)))
        list(population = population, covariates = covariates,
            covariateRef = data.frame(covariateId = ids,
                covariateName = paste("Synthetic feature", seq_along(ids)),
                analysisId = c(rep(1, 6), 2, 1)),
            analysisRef = data.frame(analysisId = c(1, 2),
                analysisName = c("Synthetic binary", "Synthetic continuous"),
                domainId = "Synthetic", isBinary = c("Y", "N"), missingMeansZero = "Y"))
    })
    names(sites) <- names(b1Settings$sizes)
    list(sites = sites, covariateIds = ids,
         scales = stats::setNames(b1Settings$scales, as.character(ids)))
}

b1Prepare <- function(fixture) do.call(preparePsData, fixture)
b1Close <- function(data) for (site in data$sites) Andromeda::close(site$cohortMethodData)
b1Fit <- function(data, method) {
    fitPs(data, method, priorVariance = b1Settings$variance,
        control = do.call(Cyclops::createControl, b1Settings$control),
        startingCoefficients = stats::setNames(rep(b1Settings$initial, length(data$covariateIds) + 1L),
                                               c("(Intercept)", as.character(data$covariateIds))))
}
b1Compare <- function(actual, expected, tolerance = b1Settings$tolerance) {
    expect_length(actual, length(expected))
    expect_true(all(is.finite(c(actual, expected))))
    error <- abs(actual - expected)
    budget <- tolerance[["absolute"]] + tolerance[["relative"]] * pmax(abs(actual), abs(expected))
    expect_true(all(error <= budget))
    max(error)
}
b1Pairs <- function(population) {
    sort(vapply(split(population$rowId, population$stratumId),
        function(rows) paste(sort(rows), collapse = ":"), ""), method = "radix")
}

referenceOutput <- Sys.getenv("FEDERATEDPS_REFERENCE_OUTPUT")
if (nzchar(referenceOutput)) {
    # Only plain synthetic data and ordinary R results cross this process boundary.
    fixture <- b1Fixture()
    prepared <- b1Prepare(fixture)
    results <- list(local = b1Fit(prepared, "local"), pooled = b1Fit(prepared, "pooled"))
    missingApi <- tryCatch(b1Fit(prepared, "simulation"), error = conditionMessage)
    stopifnot(is.character(missingApi), grepl("Patched Cyclops coordinate APIs", missingApi))
    saveRDS(list(settings = b1Settings, fixture = fixture, results = results,
                 missingApi = missingApi, cyclopsPath = find.package("Cyclops")), referenceOutput)
    b1Close(prepared)
    cat("B1_REFERENCE", find.package("Cyclops"), "SUCCESS\n")
} else if (!identical(Sys.getenv("FEDERATEDPS_SETUP_ONLY"), "true")) {
    test_that("local pooled and simulation still reject nonconvergence", {
        prepared <- b1Prepare(b1Fixture())
        on.exit(b1Close(prepared), add = TRUE)
        control <- b1Settings$control
        control$maxIterations <- 1L
        initial <- stats::setNames(rep(0, length(prepared$covariateIds) + 1L),
            c("(Intercept)", as.character(prepared$covariateIds)))
        for (method in c("local", "pooled", "simulation")) {
            expect_error(fitPs(prepared, method, b1Settings$variance,
                do.call(Cyclops::createControl, control), initial), "did not converge: MAX_ITERATIONS")
        }
    })
    test_that("OHDSI tables and sparse row/feature maps remain aligned", {
        fixture <- b1Fixture()
        prepared <- b1Prepare(fixture)
        on.exit(b1Close(prepared), add = TRUE)
        expect_equal(prepared$excludedIds, 4001)
        expect_false(anyDuplicated(prepared$rowMap$rowKey) > 0)
        expect_true(anyDuplicated(prepared$rowMap$rowId) > 0)
        expect_true(all(prepared$sites$site1$x[, "2001"] == 0))
        expect_true(any(prepared$sites$site2$x[, "2001"] != 0))
        for (name in names(fixture$sites)) {
            original <- fixture$sites[[name]]
            site <- prepared$sites[[name]]
            expect_identical(site$population, original$population)
            expect_s4_class(site$x, "dgCMatrix")
            expect_identical(colnames(site$x), as.character(prepared$covariateIds))
            expect_identical(names(site$y), rownames(site$x))
            expect_equal(unname(site$y), original$population$treatment[
                match(rownames(site$x), as.character(original$population$rowId))])
            long <- original$covariates
            long <- long[long$covariateId %in% prepared$covariateIds, ]
            observed <- site$x[cbind(match(as.character(long$rowId), rownames(site$x)),
                                    match(as.character(long$covariateId), colnames(site$x)))]
            expect_equal(as.numeric(observed), unname(long$covariateValue /
                prepared$scales[as.character(long$covariateId)]))
            saved <- dplyr::collect(site$cohortMethodData$covariates)
            saved <- saved[match(paste(original$covariates$rowId, original$covariates$covariateId),
                paste(saved$rowId, saved$covariateId)), ]
            expect_equal(saved$covariateValue, original$covariates$covariateValue)
            expect_s4_class(site$cohortMethodData, "CohortMethodData")
            outcomes <- dplyr::collect(site$cohortMethodData$outcomes)
            expect_equal(nrow(outcomes), 0)
            expect_identical(names(outcomes), c("rowId", "outcomeId", "daysToEvent"))
        }
        bad <- fixture
        bad$sites$site1$population$rowId[2L] <- bad$sites$site1$population$rowId[1L]
        expect_error(b1Prepare(bad), "unique within")
        bad <- fixture
        bad$sites$site1$population$treatment[1L] <- 2
        expect_error(b1Prepare(bad), "binary treatment")
        bad <- fixture
        bad$sites$site1$covariates$rowId[1L] <- -1
        expect_error(b1Prepare(bad), "missing from its site")
        bad <- fixture
        bad$sites$site1$covariates <- rbind(bad$sites$site1$covariates, bad$sites$site1$covariates[1L, ])
        expect_error(b1Prepare(bad), "Duplicate rowId/covariateId")
        bad <- fixture
        bad$sites$site1$covariates$covariateValue[1L] <- Inf
        expect_error(b1Prepare(bad), "finite numeric")
        bad <- fixture
        bad$scales <- rev(bad$scales)
        expect_error(b1Prepare(bad), "common feature order")
        bad <- fixture
        bad$sites$site2$covariateRef$covariateName[1L] <- "Different meaning"
        expect_error(b1Prepare(bad), "Feature meanings differ")
        bad <- prepared
        bad$rowMap$rowId[1L] <- -1
        expect_error(b1Fit(bad, "pooled"), "map no longer matches")
        bad <- prepared
        colnames(bad$sites$site1$x) <- rev(colnames(bad$sites$site1$x))
        expect_error(b1Fit(bad, "pooled"), "feature order no longer match")
        bad <- prepared
        bad$sites$site1$y[1L] <- 2
        row <- match(names(bad$sites$site1$y)[1L], as.character(bad$sites$site1$population$rowId))
        bad$sites$site1$population$treatment[row] <- 2
        expect_error(b1Fit(bad, "local"), "treatment, or feature order")
    })

    test_that("fixed local, pooled and simulation PS connect to site matching and balance", {
        cat("\nB1_LOADED", find.package("FederatedPs"), find.package("Cyclops"),
            find.package("CohortMethod"), "\n")
        fixture <- b1Fixture()
        data <- b1Prepare(fixture)
        on.exit(b1Close(data), add = TRUE)
        results <- lapply(c("local", "pooled", "simulation"), function(method) b1Fit(data, method))
        names(results) <- c("local", "pooled", "simulation")
        for (result in results) for (name in names(fixture$sites)) {
            actual <- result$populations[[name]]
            original <- fixture$sites[[name]]$population
            restored <- actual
            restored$propensityScore <- NULL
            expect_identical(restored, original)
            expect_identical(attr(actual, "metaData"), attr(original, "metaData"))
            expect_true(all(is.finite(actual$propensityScore)))
            expect_false(anyDuplicated(actual$rowId) > 0)
        }
        psError <- max(vapply(names(data$sites), function(name) b1Compare(
            results$simulation$populations[[name]]$propensityScore,
            results$pooled$populations[[name]]$propensityScore), 0.0))
        objectiveError <- b1Compare(results$simulation$models$global$objective,
                                    results$pooled$models$global$objective)
        expect_equal(results$simulation$models$global$iterations, results$pooled$models$global$iterations)
        cat("\nB1_POOLED_SIMULATION_MAX_ERRORS rawPS", format(psError, digits = 10),
            "objective", format(objectiveError, digits = 10), "\n")
        referenceInput <- Sys.getenv("FEDERATEDPS_REFERENCE_INPUT")
        if (nzchar(referenceInput)) {
            reference <- readRDS(referenceInput)
            expect_identical(reference$settings, b1Settings)
            expect_identical(reference$fixture, fixture)
            expect_false(identical(reference$cyclopsPath, find.package("Cyclops")))
            referenceError <- 0
            for (method in c("local", "pooled")) {
                for (name in names(data$sites)) {
                    referenceError <- max(referenceError, b1Compare(
                        results[[method]]$populations[[name]]$propensityScore,
                        reference$results[[method]]$populations[[name]]$propensityScore))
                }
                for (model in names(results[[method]]$models)) {
                    referenceError <- max(referenceError, b1Compare(results[[method]]$models[[model]]$objective,
                        reference$results[[method]]$models[[model]]$objective))
                }
            }
            cat("B1_UNMODIFIED_REFERENCE_MAX_ERROR", referenceError, "\n")
        }
        summaries <- list()
        matched <- list()
        balanceMeanError <- 0
        for (name in names(data$sites)) {
            matched[[name]] <- list()
            for (method in names(results)) {
                population <- results[[method]]$populations[[name]]
                population <- population[order(population$rowId), ]
                matchingArgs <- do.call(CohortMethod::createMatchOnPsArgs, b1Settings$matching)
                after <- CohortMethod::matchOnPs(population, matchingArgs)
                repeated <- CohortMethod::matchOnPs(population, matchingArgs)
                expect_identical(after, repeated)
                expect_gt(sum(after$treatment == 1), 0)
                expect_gt(sum(after$treatment == 0), 0)
                expect_true(all(after$rowId %in% population$rowId))
                expect_equal(after$propensityScore, population$propensityScore[match(after$rowId, population$rowId)])
                expect_true(all(table(after$stratumId, after$treatment) == 1))
                matched[[name]][[method]] <- after
                balance <- CohortMethod::computeCovariateBalance(after, data$sites[[name]]$cohortMethodData,
                    do.call(CohortMethod::createComputeCovariateBalanceArgs, b1Settings$balance))
                long <- fixture$sites[[name]]$covariates
                expect_setequal(balance$covariateId, unique(long$covariateId))
                if (method == "local") {
                    beta <- results$local$models[[name]]$coefficients[-1L]
                    expect_true(any(as.character(balance$covariateId) %in% names(beta)[beta == 0]))
                }
                # Check OHDSI's input join and raw scale with independent group sums.
                for (stage in c("before", "after")) {
                    selected <- if (stage == "before") population else after
                    observed <- balance$covariateId %in% unique(long$covariateId[long$rowId %in% selected$rowId])
                    for (group in c(0, 1)) {
                        rows <- selected$rowId[selected$treatment == group]
                        means <- vapply(balance$covariateId, function(id) {
                            sum(long$covariateValue[long$covariateId == id & long$rowId %in% rows]) / length(rows)
                        }, 0.0)
                        column <- paste0(stage, "MatchingMean", if (group == 1) "Target" else "Comparator")
                        # CohortMethod returns NA when this feature has no long
                        # rows at all in the selected population. Do not fill it.
                        expect_identical(is.na(balance[[column]]), !observed)
                        balanceMeanError <- max(balanceMeanError, b1Compare(balance[[column]][observed],
                            means[observed], b1Settings$balanceTolerance))
                    }
                }
                summaries[[length(summaries) + 1L]] <- data.frame(site = name, method = method,
                    targetBefore = sum(population$treatment == 1), comparatorBefore = sum(population$treatment == 0),
                    targetAfter = sum(after$treatment == 1), comparatorAfter = sum(after$treatment == 0),
                    targetRetention = sum(after$treatment == 1) / sum(population$treatment == 1),
                    comparatorRetention = sum(after$treatment == 0) / sum(population$treatment == 0),
                    balanceFeatures = nrow(balance), undefinedSmd = sum(!is.finite(balance$afterMatchingStdDiff)),
                    maxAbsSmdBefore = max(abs(balance$beforeMatchingStdDiff), na.rm = TRUE),
                    maxAbsSmdAfter = max(abs(balance$afterMatchingStdDiff), na.rm = TRUE))
                if (name == "site1" && method == "simulation") {
                    plot <- CohortMethod::plotCovariateBalanceScatterPlot(balance)
                    expect_gt(nrow(ggplot2::ggplot_build(plot)$data[[1L]]), 0)
                    file <- tempfile(fileext = ".png")
                    ggplot2::ggsave(file, plot, width = 4, height = 4, dpi = 80)
                    expect_gt(file.info(file)$size, 0)
                }
            }
            pairsEqual <- identical(b1Pairs(matched[[name]]$pooled), b1Pairs(matched[[name]]$simulation))
            cat("B1_MATCHED_PAIRS", name, "pooled_simulation_equal", pairsEqual, "\n")
        }
        cat("B1_MATCHING_BALANCE_SUMMARY\n")
        print(do.call(rbind, summaries), digits = 8, row.names = FALSE)
        cat("B1_RAW_BALANCE_MEAN_MAX_ERROR", format(balanceMeanError, digits = 10), "\n")
    })

    test_that("independent reference process is identified", {
        input <- Sys.getenv("FEDERATEDPS_REFERENCE_INPUT")
        if (!nzchar(input)) skip("Set FEDERATEDPS_REFERENCE_INPUT for the separate unmodified Cyclops reference")
        reference <- readRDS(input)
        expect_match(reference$missingApi, "Patched Cyclops coordinate APIs")
        expect_true(all(vapply(reference$results, function(result) {
            all(vapply(result$models, function(model) model$returnFlag == "SUCCESS", TRUE))
        }, TRUE)))
    })
}
