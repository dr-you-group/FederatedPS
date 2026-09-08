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

b1Fixture <- function(sizes = b1Settings$sizes) {
    set.seed(b1Settings$seed)
    ids <- b1Settings$covariateIds
    sites <- list()
    for (name in names(sizes)) {
        n <- sizes[[name]]
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
        sites[[name]] <- list(population = population, covariates = covariates,
            covariateRef = data.frame(covariateId = ids,
                covariateName = paste("Synthetic feature", seq_along(ids)),
                analysisId = c(rep(1, 6), 2, 1), conceptId = seq_along(ids)),
            analysisRef = data.frame(analysisId = c(1, 2),
                analysisName = c("Synthetic binary", "Synthetic continuous"),
                domainId = "Synthetic", isBinary = c("Y", "N"), missingMeansZero = "Y"))
    }
    list(sites = sites, covariateIds = ids,
         scales = stats::setNames(b1Settings$scales, as.character(ids)))
}

makeCmData <- function(site) {
    loadNamespace("CohortMethod")
    data <- Andromeda::andromeda(cohorts = site$population, covariates = site$covariates,
        covariateRef = site$covariateRef, analysisRef = site$analysisRef,
        outcomes = data.frame(rowId = numeric(), outcomeId = numeric(), daysToEvent = integer()))
    attr(data, "metaData") <- list(populationSize = nrow(site$population), outcomeIds = numeric(),
        targetId = 1545958, comparatorId = 1539403)
    class(data) <- "CohortMethodData"
    attr(class(data), "package") <- "CohortMethod"
    data
}

runFederated <- function(fixture, directory, control = b1Settings$control,
                         fitArgs = list(covariateIds = fixture$covariateIds, scales = fixture$scales)) {
    jobs <- list(aggregator = NULL)
    for (site in names(fixture$sites)) jobs[[site]] <- fixture$sites[[site]]
    libraryPath <- Sys.getenv("R_LIBS")
    Sys.setenv(R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep))
    on.exit(Sys.setenv(R_LIBS = libraryPath), add = TRUE)
    cluster <- parallel::makePSOCKcluster(length(jobs))
    on.exit(parallel::stopCluster(cluster), add = TRUE)
    parallel::clusterEvalQ(cluster, library(FederatedPs))
    result <- parallel::clusterMap(cluster, function(site, data, sites, directory, fitArgs, control, makeData) {
        config <- pda::getCloudConfig(site_id = site, dir = directory)
        tryCatch({
            if (site == "aggregator") {
                return(FederatedPs::aggregatePs(config, sites, "test", timeout = 10))
            }
            cm <- makeData(data)
            on.exit(Andromeda::close(cm))
            do.call(FederatedPs::fitPs, c(list(cohortMethodData = cm, population = data$population,
                config = config, runId = "test",
                control = do.call(Cyclops::createControl, control), timeout = 10), fitArgs))
        }, error = function(e) list(error = conditionMessage(e)))
    }, names(jobs), jobs, MoreArgs = list(sites = names(fixture$sites), directory = directory,
        fitArgs = fitArgs, control = control,
        makeData = makeCmData), SIMPLIFY = FALSE)
    names(result) <- names(jobs)
    result
}

pooledReference <- function(fixture) {
    matrices <- outcomes <- list()
    for (site in names(fixture$sites)) {
        data <- fixture$sites[[site]]
        rowOrder <- order(data$population$rowId)
        columns <- match(data$covariates$covariateId, fixture$covariateIds)
        matrices[[site]] <- Matrix::sparseMatrix(
            i = match(data$covariates$rowId, data$population$rowId[rowOrder]), j = columns,
            x = data$covariates$covariateValue / fixture$scales[columns],
            dims = c(nrow(data$population), length(fixture$covariateIds)))
        outcomes[[site]] <- data$population$treatment[rowOrder]
    }
    x <- do.call(rbind, matrices)
    keep <- Matrix::colSums(x != 0) > 0
    x <- x[, keep, drop = FALSE]
    colnames(x) <- as.character(fixture$covariateIds[keep])
    data <- Cyclops::createCyclopsData(y ~ 1,
        data = data.frame(y = unlist(outcomes, use.names = FALSE)), sx = x, modelType = "lr")
    data$coefficientNames <- c("(Intercept)", colnames(x))
    Cyclops::fitCyclopsModel(data, prior = Cyclops::createPrior("laplace", variance = 1,
        exclude = "(Intercept)", useCrossValidation = FALSE),
        control = do.call(Cyclops::createControl, b1Settings$control),
        startingCoefficients = rep(0, ncol(x) + 1L))
}

matchedPairs <- function(population) {
    sort(vapply(split(population$rowId, population$stratumId),
        function(rows) paste(sort(rows), collapse = ":"), ""))
}
