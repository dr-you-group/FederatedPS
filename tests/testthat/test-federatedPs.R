test_that("separate hospitals preserve pooled PS, matching and balance", {
    fixture <- b1Fixture()
    directory <- tempfile("pda-")
    dir.create(directory)
    on.exit(unlink(directory, recursive = TRUE))
    result <- runFederated(fixture, directory)
    for (site in names(fixture$sites)) expect_null(result[[site]]$error)
    reference <- pooledReference(fixture)
    expect_equal(result$aggregator, coef(reference), tolerance = 1e-7)
    expect_false("4001" %in% names(result$aggregator))
    expect_true("2001" %in% names(result$aggregator))
    ps <- unname(predict(reference))
    offset <- 0L
    for (site in names(fixture$sites)) {
        original <- fixture$sites[[site]]
        population <- result[[site]]
        expected <- original$population
        expected$propensityScore <- ps[offset + match(expected$rowId, sort(expected$rowId))]
        offset <- offset + nrow(expected)
        expect_identical(population$rowId, expected$rowId)
        expect_identical(population$treatment, expected$treatment)
        expect_identical(class(population), class(expected))
        expect_equal(population$propensityScore, expected$propensityScore, tolerance = 1e-7)
        expect_equal(attr(population, "metaData")$psModelCoef, coef(reference), tolerance = 1e-7)
        args <- do.call(CohortMethod::createMatchOnPsArgs, b1Settings$matching)
        matched <- CohortMethod::matchOnPs(population[order(population$rowId), ], args)
        expectedMatch <- CohortMethod::matchOnPs(expected[order(expected$rowId), ], args)
        expect_identical(matchedPairs(matched), matchedPairs(expectedMatch))
        expect_gt(nrow(matched), 0)
        cm <- makeCmData(original)
        balance <- CohortMethod::computeCovariateBalance(matched, cm,
            do.call(CohortMethod::createComputeCovariateBalanceArgs, b1Settings$balance))
        expect_gt(nrow(CohortMethod::getPsModel(population, cm)), 0)
        Andromeda::close(cm)
        for (stage in c("before", "after")) {
            selected <- if (stage == "before") population else matched
            long <- original$covariates
            observed <- balance$covariateId %in% long$covariateId[long$rowId %in% selected$rowId]
            for (group in 0:1) {
                rows <- selected$rowId[selected$treatment == group]
                means <- vapply(balance$covariateId, function(id) {
                    sum(long$covariateValue[long$covariateId == id & long$rowId %in% rows]) / length(rows)
                }, 0.0)
                column <- paste0(stage, "MatchingMean", if (group == 1) "Target" else "Comparator")
                expect_identical(is.na(balance[[column]]), !observed)
                expect_equal(balance[[column]][observed], means[observed], tolerance = 1e-10)
            }
        }
    }
    config <- pda::getCloudConfig("aggregator", dir = file.path(directory, "test", "1"))
    packet <- pda::pdaGet("test_1_site1", config)
    expect_named(packet, c("coordinate", "statistics"))
    expect_length(packet$statistics, 2)
    config <- pda::getCloudConfig("aggregator", dir = directory)
    expect_error(aggregatePs(config, names(fixture$sites), "test"), "new runId")
})

test_that("three hospitals agree on one model and retain locally absent features", {
    fixture <- b1Fixture(c(site1 = 120L, site2 = 96L, site3 = 96L))
    directory <- tempfile("pda-")
    dir.create(directory)
    on.exit(unlink(directory, recursive = TRUE))
    result <- runFederated(fixture, directory)
    reference <- pooledReference(fixture)
    expect_equal(result$aggregator, coef(reference), tolerance = 1e-7)
    ps <- unname(predict(reference))
    offset <- 0L
    for (site in names(fixture$sites)) {
        population <- result[[site]]
        expect_null(population$error)
        expect_equal(attr(population, "metaData")$psModelCoef, coef(reference), tolerance = 1e-7)
        expect_equal(population$propensityScore,
            ps[offset + match(population$rowId, sort(population$rowId))], tolerance = 1e-7)
        offset <- offset + nrow(population)
    }
})

test_that("nonconvergence is reported by hospitals", {
    directory <- tempfile("pda-")
    dir.create(directory)
    on.exit(unlink(directory, recursive = TRUE))
    control <- b1Settings$control
    control$maxIterations <- 1L
    result <- runFederated(b1Fixture(), directory, control)
    expect_match(result$site1$error, "MAX_ITERATIONS")
    expect_match(result$site2$error, "MAX_ITERATIONS")
})

test_that("ambiguous rows, labels and sparse coordinates are rejected before exchange", {
    site <- b1Fixture()$sites$site1
    cm <- makeCmData(site)
    on.exit(Andromeda::close(cm))
    directory <- tempfile("pda-")
    dir.create(directory)
    on.exit(unlink(directory, recursive = TRUE), add = TRUE)
    config <- pda::getCloudConfig("site1", dir = directory)
    fit <- function(population) fitPs(cm, population, b1Settings$covariateIds,
                                    config = config, runId = "validation")
    bad <- site$population
    bad$rowId[2] <- bad$rowId[1]
    expect_error(fit(bad), "rowId")
    bad <- site$population
    bad$treatment[1] <- 2
    expect_error(fit(bad), "binary")
    cm$covariates <- rbind(site$covariates, site$covariates[1, ])
    expect_error(fit(site$population), "Duplicate")
    bad <- site$covariates
    bad$covariateValue[1] <- Inf
    cm$covariates <- bad
    expect_error(fit(site$population), "finite")
})


test_that("hospitals derive one ordered feature union with default scaling", {
    fixture <- b1Fixture()
    fixture$covariateIds <- sort(fixture$covariateIds)
    fixture$scales <- rep(1, length(fixture$covariateIds))
    reference <- fixture$sites$site1$covariateRef
    fixture$sites$site1$covariateRef <- reference[reference$covariateId != 2001, ]
    directory <- tempfile("pda-")
    dir.create(directory)
    on.exit(unlink(directory, recursive = TRUE))
    result <- runFederated(fixture, directory, fitArgs = list())
    expected <- coef(pooledReference(fixture))
    expect_equal(result$aggregator, expected, tolerance = 1e-7)
    for (site in names(fixture$sites)) {
        expect_null(result[[site]]$error)
        expect_identical(result[[site]]$rowId, fixture$sites[[site]]$population$rowId)
        expect_equal(attr(result[[site]], "metaData")$psModelCoef, expected, tolerance = 1e-7)
    }
})
