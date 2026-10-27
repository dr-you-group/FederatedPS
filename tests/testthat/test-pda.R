test_that("pda exchanges preserve double precision and wait for completed writes", {
    directory <- tempfile("pda-")
    dir.create(directory)
    on.exit(unlink(directory, recursive = TRUE))
    config <- pda::getCloudConfig("site1", dir = directory)
    values <- c(1 / 3, 1e-19, pi, 1e12 + 0.1234)
    expect_message(.putPs(values, "statistics", config), NA)
    expect_identical(.getPs("statistics", config, 1), values)
    expect_error(.getPs("missing", config, 0), "Timed out")
    expect_error(fitPs(NULL, data.frame(rowId = c(1, 1), treatment = 0:1), 1), "rowId")
})

test_that("cross-hospital feature and coordinate disagreements stop aggregation", {
    directory <- tempfile("pda-")
    dir.create(directory)
    on.exit(unlink(directory, recursive = TRUE))
    config <- pda::getCloudConfig("aggregator", dir = directory)
    packet <- list(coordinate = -1L, statistics = list(specification = list(features = c("1", "2")),
        reference = data.frame(covariateId = 1, analysisId = 1), present = c(TRUE, TRUE)))
    .putPs(packet, "features_0_site1", config)
    packet$statistics$specification$features <- c("2", "1")
    .putPs(packet, "features_0_site2", config)
    expect_error(aggregatePs(config, c("site1", "site2"), "features"), "features, scales")
    packet$statistics$specification <- list(features = c("1", "2"),
        cohorts = list(targetId = 1545958, comparatorId = 1539403))
    .putPs(packet, "cohorts_0_site1", config)
    packet$statistics$specification$cohorts <- list(targetId = 1539403, comparatorId = 1545958)
    .putPs(packet, "cohorts_0_site2", config)
    expect_error(aggregatePs(config, c("site1", "site2"), "cohorts"), "fitting settings")
    .putPs(list(coordinate = 1, statistics = c(1, 2, 0, 2)), "state_0_site1", config)
    .putPs(list(coordinate = 2, statistics = c(1, 2, 0, 2)), "state_0_site2", config)
    expect_error(aggregatePs(config, c("site1", "site2"), "state"), "coordinate states")
})

test_that("aggregation waits longer for both negotiations but not training or final agreement", {
    skip_if(!"local_mocked_bindings" %in% getNamespaceExports("testthat"),
            "Timeout instrumentation requires a newer testthat mocking helper")
    directory <- tempfile("pda-timeouts-")
    dir.create(directory)
    on.exit(unlink(directory, recursive = TRUE))
    readPacket <- .getPs
    waits <- numeric()
    testthat::local_mocked_bindings(.getPs = function(name, config, timeout) {
        waits <<- c(waits, timeout)
        readPacket(name, config, timeout)
    }, .package = "FederatedPs")
    specification <- list(coordinate = -1L, statistics = list(
        specification = list(protocol = .protocolVersion, features = c("1001", "2001"),
            control = list(blockSize = 1L)),
        reference = data.frame(covariateId = c(1001, 2001), analysisId = 1L),
        present = c(TRUE, TRUE)))
    training <- list(
        list(coordinate = 1L, statistics = c(1, 2, 0, 2)),
        list(coordinate = 0L, statistics = c(3, 0)),
        list(coordinate = -2L, statistics = list(coefficients = c(0, 0.1, -0.2), iterations = 1L)))
    for (negotiateUnion in c(TRUE, FALSE)) {
        runId <- if (negotiateUnion) "withunion" else "fixedfeatures"
        config <- pda::getCloudConfig("aggregator", dir = directory)
        rounds <- c(if (negotiateUnion) list(list(coordinate = -3L, statistics = c(1001, 2001))),
                    list(specification), training)
        # Real pda packets exercise serialization, round directories and the
        # completed-write marker. Only the read timeout argument is observed.
        for (i in seq_along(rounds)) {
            roundConfig <- config
            if (i > 1L) {
                roundConfig$dir <- file.path(directory, runId, i - 1L)
                dir.create(roundConfig$dir, recursive = TRUE)
            }
            for (site in c("site1", "site2"))
                .putPs(rounds[[i]], paste0(runId, "_", i - 1L, "_", site), roundConfig)
        }
        waits <- numeric()
        result <- aggregatePs(config, c("site1", "site2"), runId,
                              timeout = 2, initialTimeout = 90)
        expect_identical(waits, c(rep(90, if (negotiateUnion) 4L else 2L), rep(2, 6L)))
        expect_equal(result, c("(Intercept)" = 0, "1001" = 0.1, "2001" = -0.2))
    }
})

test_that("both site fitting APIs scope the initial timeout to feature negotiation", {
    skip_if(!"local_mocked_bindings" %in% getNamespaceExports("testthat"),
            "Timeout instrumentation requires a newer testthat mocking helper")
    directory <- tempfile("pda-site-timeouts-")
    dir.create(directory)
    on.exit(unlink(directory, recursive = TRUE))
    site <- b1Fixture(c(site1 = 24L))$sites$site1
    cm <- makeCmData(site)
    on.exit(Andromeda::close(cm), add = TRUE)
    config <- pda::getCloudConfig("site1", dir = directory)
    control <- do.call(Cyclops::createControl, b1Settings$control)
    x <- Matrix::sparseMatrix(
        i = match(site$covariates$rowId, site$population$rowId),
        j = match(site$covariates$covariateId, site$covariateRef$covariateId),
        x = site$covariates$covariateValue,
        dims = c(nrow(site$population), nrow(site$covariateRef)),
        dimnames = list(NULL, as.character(site$covariateRef$covariateId)))
    packet <- NULL
    coordinates <- integer()
    waits <- numeric()
    # Echoing sufficient statistics emulates an immediate single-site peer.
    # Real Cyclops drives the training/convergence callbacks and final exchange;
    # no artificial sleep or database connection is involved.
    testthat::local_mocked_bindings(
        .putPs = function(value, name, config) packet <<- value,
        .getPs = function(name, config, timeout) {
            coordinate <- packet$coordinate
            coordinates <<- c(coordinates, coordinate)
            waits <<- c(waits, timeout)
            if (coordinate == -3L) sort(unique(packet$statistics))
            else if (coordinate == -1L) packet$statistics$present
            else if (coordinate == -2L) packet$statistics$coefficients
            else packet$statistics
        }, .package = "FederatedPs")
    for (api in c("cohort", "design")) {
        coordinates <- integer()
        waits <- numeric()
        if (api == "cohort") {
            result <- fitPs(cm, site$population, config = config, runId = "cohorttimeout",
                            control = control, timeout = 2, initialTimeout = 90)
        } else {
            result <- fitPsDesign(x, site$population$treatment, site$population$rowId,
                                 config = config, runId = "designtimeout",
                                 control = control, timeout = 2, initialTimeout = 90)
        }
        expect_equal(head(coordinates, 2L), c(-3L, -1L))
        expect_true(any(coordinates >= 0L))
        expect_equal(tail(coordinates, 1L), -2L)
        expect_true(all(waits[coordinates %in% c(-3L, -1L)] == 90))
        expect_true(all(waits[!coordinates %in% c(-3L, -1L)] == 2))
        expect_true(all(is.finite(result$propensityScore)))
    }
})
