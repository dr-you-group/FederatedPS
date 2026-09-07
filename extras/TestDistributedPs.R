# C1 by default; an optional fourth argument selects a nested C2 dimension.
# Runtime files stay outside the package. No native state is serialized.
args <- commandArgs(trailingOnly = TRUE)
stage <- match.arg(args[[1L]], c("reference", "setup", "register", "probe", "train", "compare", "failures", "audit", "scaleFixture", "scaleSummary", "dRegister", "dProbeBefore", "dProbe", "dReference", "dSetup", "dTrain", "dCompare", "dMatching", "convergenceInput", "convergenceCheck", "convergenceCompare"))
work <- normalizePath(args[[2L]], mustWork = TRUE)
sourcePath <- normalizePath(args[[3L]], mustWork = TRUE)
library(FederatedPs)
# Fixed before generating or fitting C2 data. Dimensions exclude the intercept.
# Generate all sparse columns first, then labels, then the site row order.
c2 <- list(seed = 20260907L, sizes = c(site1 = 1800L, site2 = 1200L),
    dimensions = c(100L, 1000L, 10000L), density = 0.01,
    labelIntercept = -0.3, labelCoefficients = c(1.1, -0.9, 0.8, -0.7, 0.6),
    remoteSweeps = c(`100` = 5000L, `1000` = 2L, `10000` = 1L),
    remoteSeconds = c(`100` = 600, `1000` = 300, `10000` = 1500),
    localSeconds = 600, totalModelSeconds = 3600,
    tolerance = c(absolute = 1e-7, relative = 1e-7),
    coordinateTolerance = c(absolute = 1e-10, relative = 1e-10))
partialTest <- length(args) >= 4L && identical(args[[4L]], "partial")
scaleP <- if (length(args) >= 4L && !partialTest) as.integer(args[[4L]]) else NA_integer_
isScale <- !is.na(scaleP)
if (isScale && !scaleP %in% c2$dimensions) stop("Unsupported C2 dimension")
if (stage == "scaleFixture") {
    set.seed(c2$seed)
    n <- sum(c2$sizes)
    p <- max(c2$dimensions)
    counts <- rbinom(p, n, c2$density)
    i <- unlist(lapply(counts, function(count) sample.int(n, count)), use.names = FALSE)
    x <- Matrix::sparseMatrix(i = i, j = rep(seq_len(p), counts), x = 1, dims = c(n, p))
    eta <- c2$labelIntercept + as.numeric(x[, seq_along(c2$labelCoefficients), drop = FALSE] %*%
        c2$labelCoefficients)
    treatment <- as.numeric(rbinom(n, 1L, plogis(eta)))
    ids <- as.numeric(10000L + seq_len(p))
    sites <- vector("list", length(c2$sizes))
    names(sites) <- names(c2$sizes)
    first <- 1L
    for (name in names(sites)) {
        size <- c2$sizes[[name]]
        selected <- first:(first + size - 1L)
        rows <- 1000 + 17 * seq_len(size)
        long <- Matrix::summary(x[selected, , drop = FALSE])
        population <- data.frame(rowId = rows, personSeqId = rows + 100000,
            treatment = treatment[selected])
        population <- population[sample.int(size), ]
        rownames(population) <- NULL
        attr(population, "metaData") <- list(synthetic = TRUE, site = name)
        covariates <- data.frame(rowId = rows[long$i], covariateId = ids[long$j], covariateValue = long$x)
        covariates <- covariates[sample.int(nrow(covariates)), ]
        rownames(covariates) <- NULL
        sites[[name]] <- list(population = population, covariates = covariates,
            covariateRef = data.frame(covariateId = ids, covariateName = paste("C2 binary", ids), analysisId = 1),
            analysisRef = data.frame(analysisId = 1, analysisName = "C2 binary",
                domainId = "Synthetic", isBinary = "Y", missingMeansZero = "Y"))
        stopifnot(setequal(population$treatment, c(0, 1)))
        first <- first + size
    }
    for (dimension in c2$dimensions) {
        path <- file.path(work, paste0("p", dimension))
        dir.create(path, showWarnings = FALSE)
        subset <- lapply(sites, function(site) {
            site$covariates <- site$covariates[site$covariates$covariateId %in% ids[seq_len(dimension)], ]
            site$covariateRef <- site$covariateRef[seq_len(dimension), ]
            site
        })
        saveRDS(list(sites = subset, covariateIds = ids[seq_len(dimension)],
            scales = stats::setNames(rep(1, dimension), as.character(ids[seq_len(dimension)]))),
            file.path(path, "fixture.rds"))
    }
    cat("C2_MAXIMUM_SPARSE_INPUT", nrow(x), ncol(x), "nnz", length(x@x),
        "R_object_bytes", as.numeric(object.size(x)), "\n")
    saveRDS(c2, file.path(work, "settings.rds"))
}
# A response failure must terminate this run; never replay a mutating request.
options(opal.retry.times = 1L, datashield.errors.print = TRUE)
if (stage %in% c("register", "probe", "train", "failures", "audit", "dRegister", "dProbeBefore", "dProbe", "dTrain")) {
    # The isolated Opal certificate names localhost. Trust its public certificate
    # and route that host to the Opal service, retaining TLS verification.
    options(opal.opts = list(cainfo = normalizePath(file.path(work, "opal-public.pem"),
        mustWork = TRUE), connect_to = "localhost:8443:opal:8443",
        ssl_verifyhost = 2L, ssl_verifypeer = TRUE))
}

if (stage %in% c("reference", "setup")) {
    Sys.setenv(FEDERATEDPS_SETUP_ONLY = "true")
    definitions <- new.env()
    sys.source(file.path(sourcePath, "tests/testthat/test-federatedPs.R"), definitions)
    fixture <- if (isScale) readRDS(file.path(work, "fixture.rds")) else definitions$b1Fixture()
    settings <- definitions$b1Settings
    if (isScale) {
        settings$covariateIds <- fixture$covariateIds
        settings$scales <- unname(fixture$scales)
        settings$sizes <- c2$sizes
        definitions$b1Settings <- settings
    }
    prepareStart <- proc.time()[["elapsed"]]
    prepared <- definitions$b1Prepare(fixture)
    prepareSeconds <- proc.time()[["elapsed"]] - prepareStart
    if (isScale) {
        metadata <- list(nominalP = scaleP, actualP = length(prepared$covariateIds),
            coordinates = length(prepared$covariateIds) + 1L, excludedIds = prepared$excludedIds,
            sizes = c2$sizes, target = vapply(prepared$sites, function(site) sum(site$y), 0.0),
            nnz = vapply(prepared$sites, function(site) length(site$x@x), 0L),
            sparseBytes = vapply(prepared$sites, function(site) as.numeric(object.size(site$x)), 0.0))
        saveRDS(metadata, file.path(work, "metadata.rds"))
        print(metadata)
    }
    if (stage == "reference") {
        stopifnot(find.package("Cyclops") == "/opt/federatedps/reference-library/Cyclops")
        fitStart <- proc.time()[["elapsed"]]
        result <- if (isScale) list(pooled = definitions$b1Fit(prepared, "pooled")) else
            list(local = definitions$b1Fit(prepared, "local"), pooled = definitions$b1Fit(prepared, "pooled"))
        fitSeconds <- proc.time()[["elapsed"]] - fitStart
        missingApi <- tryCatch(definitions$b1Fit(prepared, "simulation"), error = conditionMessage)
        stopifnot(is.character(missingApi), grepl("Patched Cyclops coordinate APIs", missingApi))
        saveRDS(list(settings = settings, fixture = fixture, results = result,
            missingApi = missingApi, cyclopsPath = find.package("Cyclops"),
            prepareSeconds = prepareSeconds, fitSeconds = fitSeconds), file.path(work, "reference.rds"))
    } else {
        stopifnot(find.package("Cyclops") == "/opt/federatedps/library/Cyclops")
        fitStart <- proc.time()[["elapsed"]]
        simulation <- NULL
        if (!isScale || scaleP != 10000L) {
            simulation <- definitions$b1Fit(prepared, "simulation")
            simulation$fitSeconds <- proc.time()[["elapsed"]] - fitStart
            simulation$prepareSeconds <- prepareSeconds
            saveRDS(simulation, file.path(work, "simulation.rds"))
        }
        baseline <- readRDS(file.path(work, "reference.rds"))
        stopifnot(identical(baseline$fixture, fixture), identical(baseline$settings, settings))
        initial <- stats::setNames(rep(settings$initial, length(prepared$covariateIds) + 1L),
            c("(Intercept)", as.character(prepared$covariateIds)))
        for (name in names(fixture$sites)) {
            input <- list(synthetic = TRUE, name = name, site = fixture$sites[[name]],
                covariateIds = fixture$covariateIds, scales = fixture$scales,
                excludedIds = prepared$excludedIds,
                settings = list(priorVariance = settings$variance,
                    control = settings$control, startingCoefficients = initial),
                evaluation = list(populations = list(
                    local = if (isScale) NULL else baseline$results$local$populations[[name]],
                    pooled = baseline$results$pooled$populations[[name]],
                    simulation = simulation$populations[[name]]),
                    matching = settings$matching, balance = settings$balance))
            if (isScale || partialTest) {
                input$settings$control$maxIterations <- if (partialTest) 1L else c2$remoteSweeps[[as.character(scaleP)]]
                input$evaluation <- NULL
            }
            saveRDS(input, file.path(work, paste0(name, ".rds")))
        }
        # Only this separate setup process sees pooled X. The probe reads these
        # few reference statistics, never the pooled sparse input or population.
        x <- do.call(rbind, lapply(prepared$sites, function(site) site$x))
        rownames(x) <- prepared$rowMap$rowKey
        y <- stats::setNames(unlist(lapply(prepared$sites, function(site) unname(site$y))),
            rownames(x))
        oracleControl <- settings$control
        if (partialTest) oracleControl$maxIterations <- 1L
        if (isScale) oracleControl$maxIterations <- c2$remoteSweeps[[as.character(scaleP)]]
        state <- Cyclops::initializeCyclopsCoordinateDescent(y, x,
            Cyclops::createPrior("laplace", variance = settings$variance,
                exclude = "(Intercept)", useCrossValidation = FALSE),
            do.call(Cyclops::createControl, oracleControl), initial)
        likelihood <- Cyclops::getCyclopsCoordinateFit(state)$log_likelihood
        done <- Cyclops::checkCyclopsCoordinateConvergence(state, likelihood)
        reference <- vector("list", 2L)
        trace <- list()
        sweep <- 0L
        sweepLimit <- if (partialTest) 1L else if (isScale) c2$remoteSweeps[[as.character(scaleP)]] else Inf
        oracleStart <- proc.time()[["elapsed"]]
        while (!done && sweep < sweepLimit) {
            for (coordinate in names(initial)) {
                statistics <- Cyclops::getCyclopsCoordinateStatistics(state, coordinate)
                update <- Cyclops::updateCyclopsCoordinate(state, coordinate,
                    statistics[["gradient"]], statistics[["curvature"]])
                i <- length(trace) + 1L
                trace[[i]] <- c(statistics[1:2], update)
                if (i <= 2L) reference[[i]] <- list(coordinate = coordinate, statistics = statistics, update = update)
            }
            fit <- Cyclops::getCyclopsCoordinateFit(state)
            done <- Cyclops::checkCyclopsCoordinateConvergence(state, fit$log_likelihood)
            sweep <- sweep + 1L
        }
        if (isScale || partialTest) {
            fit <- Cyclops::getCyclopsCoordinateFit(state)
            stopifnot(fit$finished, fit$iterations == sweep, fit$nextCoordinate == 1L,
                fit$return_flag %in% c("SUCCESS", "MAX_ITERATIONS"))
            coefficients <- stats::coef(fit, ignoreConvergence = fit$return_flag == "MAX_ITERATIONS")
            rawPs <- stats::predict(fit)
            linear <- as.numeric(x %*% coefficients[-1L]) + coefficients[[1L]]
            pilot <- list(sweeps = sweep, seconds = proc.time()[["elapsed"]] - oracleStart,
                objective = -(fit$log_likelihood + fit$log_prior), rawPs = rawPs,
                coefficients = coefficients, returnFlag = fit$return_flag,
                bounds = vapply(tail(trace, length(initial)), function(x) x[["bound"]], 0.0))
            saveRDS(pilot, file.path(work, "pilot-reference.rds"))
            for (name in names(prepared$sites)) {
                input <- readRDS(file.path(work, paste0(name, ".rds")))
                selected <- which(prepared$rowMap$site == name)
                keys <- rownames(prepared$sites[[name]]$x)
                stopifnot(identical(as.character(prepared$rowMap$rowId[selected]), keys),
                    identical(names(rawPs)[selected], prepared$rowMap$rowKey[selected]))
                input$evaluation <- list(type = "sweep", step = as.integer(length(trace)),
                    rawPs = stats::setNames(unname(rawPs[selected]), keys),
                    linearPredictor = stats::setNames(linear[selected], keys))
                saveRDS(input, file.path(work, paste0(name, ".rds")))
            }
        }
        saveRDS(list(likelihood = likelihood, coordinates = reference),
            file.path(work, "probe-reference.rds"))
        saveRDS(do.call(rbind, trace), file.path(work, "coordinate-reference.rds"))
    }
    definitions$b1Close(prepared)
    cat(stage, "SUCCESS", find.package("FederatedPs"), find.package("Cyclops"), "\n")
}

if (stage == "register") {
    administrator <- opalr::opal.login(username = "administrator",
        password = Sys.getenv("C1_OPAL_PASSWORD"), url = "https://localhost:8443")
    if (!opalr::oadmin.user_exists(administrator, "c1-researcher")) {
        invisible(opalr::oadmin.user_add(administrator, "c1-researcher",
            password = Sys.getenv("C1_RESEARCH_PASSWORD")))
    }
    opalr::dsadmin.perm_add(administrator, "c1-researcher", permission = "use")
    for (profile in c("c1-site1", "c1-site2")) {
        # Opal creates a profile when it discovers a Rock cluster.
        if (!opalr::dsadmin.profile_exists(administrator, profile)) {
            opalr::dsadmin.profile_create(administrator, profile, cluster = profile)
        }
        opalr::dsadmin.profile_access(administrator, profile, restricted = TRUE)
        opalr::dsadmin.profile_init(administrator, profile, packages = "FederatedPs")
        opalr::dsadmin.profile_perm_add(administrator, profile, "c1-researcher")
        opalr::dsadmin.profile_enable(administrator, profile)
        methods <- opalr::dsadmin.get_methods(administrator, type = "assign", profile = profile)
        stopifnot("initializePsSiteDS" %in% methods$name)
        stopifnot(all(c("preparePsCvDS", "applyPsPreprocessingDS", "setPsPriorDS") %in% methods$name))
        aggregates <- opalr::dsadmin.get_methods(administrator, type = "aggregate", profile = profile)
        stopifnot(all(c("getPsPreprocessingDS", "getPsValidationDS") %in% aggregates$name))
        print(opalr::dsadmin.profile(administrator, profile)[c("name", "cluster", "restrictedAccess", "enabled")])
    }
    opalr::opal.logout(administrator)
}

if (stage == "dRegister") {
    administrator <- opalr::opal.login(username = "administrator",
        password = Sys.getenv("C1_OPAL_PASSWORD"), url = "https://localhost:8443")
    for (profile in c("c1-site1", "c1-site2")) {
        configuration <- opalr::dsadmin.profile(administrator, profile)
        stopifnot(configuration$restrictedAccess, configuration$enabled,
            identical(configuration$cluster, profile))
        before <- opalr::dsadmin.get_methods(administrator, type = "assign", profile = profile)
        aggregates <- opalr::dsadmin.get_methods(administrator, type = "aggregate", profile = profile)
        existing <- before[before$name == "c", , drop = FALSE]
        # set_method removes an existing mapping: never overwrite a different one.
        if (nrow(existing)) {
            stopifnot(nrow(existing) == 1L, identical(existing$class, "function"),
                identical(existing$value, "base::c"))
        } else {
            opalr::dsadmin.set_method(administrator, "c", func = "base::c",
                type = "assign", profile = profile)
        }
        after <- opalr::dsadmin.get_methods(administrator, type = "assign", profile = profile)
        stopifnot(identical(after$value[after$name == "c"], "base::c"),
            setequal(after$name, c(before$name, "c")), !"c" %in% aggregates$name,
            identical(after$value[match(before$name, after$name)], before$value),
            identical(aggregates, opalr::dsadmin.get_methods(administrator,
                type = "aggregate", profile = profile)))
        cat("D_PROFILE", profile, "restricted ASSIGN c -> base::c; AGGREGATE unchanged\n")
        print(after[c("name", "type", "value")], row.names = FALSE)
        print(aggregates[c("name", "type", "value")], row.names = FALSE)
    }
    opalr::opal.logout(administrator)
}

if (stage %in% c("probe", "train", "failures", "dProbeBefore", "dProbe", "dTrain")) {
    library(DSOpal)
    logins <- data.frame(server = c("site1", "site2"), url = "https://localhost:8443",
        user = "c1-researcher", password = Sys.getenv("C1_RESEARCH_PASSWORD"),
        profile = c("c1-site1", "c1-site2"))
    connections <- DSI::datashield.login(logins, assign = FALSE, failSafe = FALSE,
        opts = getOption("opal.opts"))
}

if (stage %in% c("dProbeBefore", "dProbe")) {
    probeD <- function() {
        on.exit(DSI::datashield.logout(connections), add = TRUE)
        DSI::datashield.assign.expr(connections, "input", "loadPsSyntheticDS()", async = FALSE)
        DSI::datashield.assign.expr(connections, "raw", "preparePsCvDS(input, 2, 20260907)", async = FALSE)
        summaries <- DSI::datashield.aggregate(connections, "getPsPreprocessingDS(raw, 1)", async = FALSE)
        spec <- combinePsSummaries(summaries, minFraction = 0.05)
        # The same nested numeric c(...) boundary used by fitPsDataShieldCv.
        expression <- sprintf("applyPsPreprocessingDS(raw, 1, c(%s), c(%s))",
            paste(sprintf("%.17g", spec$covariateIds), collapse = ","),
            paste(sprintf("%.17g", spec$scales), collapse = ","))
        cat("D_PREPROCESSING_EXPRESSION", expression, "\n")
        if (stage == "dProbeBefore") {
            for (site in names(connections)) {
                failed <- tryCatch(DSI::datashield.assign.expr(connections[site], "prepared",
                    expression, async = FALSE), error = conditionMessage)
                cat("D_BEFORE_REGISTRATION", site, failed, "\n")
                stopifnot(is.character(failed),
                    grepl("No such DataSHIELD 'ASSIGN' method", failed, fixed = TRUE),
                    grepl("with name: c", failed, fixed = TRUE))
            }
            return(invisible(NULL))
        }
        # Scalars travel through ASSIGN c, then the existing limited aggregate.
        # Seventeen decimal digits preserve float64, including tiny increments.
        values <- c(0, -0.12345678901234567, 2^-48, pi, 1 + 2^-52)
        for (i in seq_along(values)) DSI::datashield.assign.expr(connections, paste0("value", i),
            sprintf("c(%.17g)", values[i]), async = FALSE)
        roundTrip <- DSI::datashield.aggregate(connections,
            "checkPsPrecisionDS(value1, value2, value3, value4, value5)", async = FALSE)
        stopifnot(all(vapply(roundTrip, identical, TRUE, values)))
        cat("D_ASSIGN_FLOAT64_MAX_ERROR", max(abs(unlist(roundTrip) - rep(values, 2))), "\n")
        cases <- lapply(c(1L, 2L, 0L), function(fold) {
            summary <- DSI::datashield.aggregate(connections,
                sprintf("getPsPreprocessingDS(raw, %d)", fold), async = FALSE)
            list(fold = fold, spec = combinePsSummaries(summary, minFraction = 0.05))
        })
        # Positional vectors: the receiver derives names from the agreed IDs.
        # Also exercise a singleton and nonadjacent IDs with noninteger scales.
        for (positions in list(1L, c(2L, 4L))) {
            subset <- spec
            subset$covariateIds <- subset$covariateIds[positions]
            subset$scales <- subset$scales[positions] + 0.125
            cases[[length(cases) + 1L]] <- list(fold = 1L, spec = subset)
        }
        for (i in seq_along(cases)) {
            candidate <- cases[[i]]
            ids <- candidate$spec$covariateIds
            scales <- candidate$spec$scales
            expression <- sprintf("applyPsPreprocessingDS(raw, %d, c(%s), c(%s))", candidate$fold,
                paste(sprintf("%.17g", ids), collapse = ","),
                paste(sprintf("%.17g", scales), collapse = ","))
            DSI::datashield.assign.expr(connections, "prepared", expression, async = FALSE)
            DSI::datashield.assign.expr(connections, "prepared", "setPsPriorDS(prepared, 1)", async = FALSE)
            # Initialize only; no convergence check, coordinate update or fit.
            run <- paste0("Dprobe", i)
            DSI::datashield.assign.expr(connections, "probeState",
                sprintf('initializePsSiteDS(prepared, "%s")', run), async = FALSE)
            status <- DSI::datashield.aggregate(connections,
                sprintf('getPsSiteStatusDS(probeState, "%s", 0)', run), async = FALSE)
            for (site in names(status)) {
                received <- status[[site]]$specification
                stopifnot(identical(unname(received$scales), unname(scales)),
                    identical(names(received$scales), as.character(ids)),
                    identical(names(received$settings$startingCoefficients)[-1L], as.character(ids)),
                    received$trainingFold == candidate$fold, status[[site]]$step == 0L,
                    status[[site]]$initializations == 1L)
                cat("D_VECTOR_PROBE", i, site, "fold", candidate$fold, "length", length(ids),
                    "order_names_values_exact; initialization_only; native", status[[site]]$process$cyclopsNative, "\n")
            }
            stopifnot(length(unique(vapply(status, function(x)
                paste(x$process$host, x$process$pid), ""))) == 2L)
        }
        stopifnot(2001 %in% spec$covariateIds,
            summaries$site1$nonzero["2001"] == 0, summaries$site2$nonzero["2001"] > 0)
        invalid <- c(
            "applyPsPreprocessingDS(raw, 1, c(), c())",
            "applyPsPreprocessingDS(raw, 1, c(7001,1001), c(2))",
            "applyPsPreprocessingDS(raw, 1, c(1001,1001), c(2,2))",
            "applyPsPreprocessingDS(raw, 1, c(1001.5), c(2))",
            "applyPsPreprocessingDS(raw, 1, c(999999), c(2))",
            "applyPsPreprocessingDS(raw, 1, c(1001,7001), c(2,2))",
            "applyPsPreprocessingDS(raw, 1, c(1001), c(0))",
            "applyPsPreprocessingDS(raw, 1, c(1001), c(-1))",
            "applyPsPreprocessingDS(raw, 1, c(1001), c(1e309))")
        for (expression in invalid) {
            rejected <- tryCatch(DSI::datashield.assign.expr(connections, "invalid",
                expression, async = FALSE), error = conditionMessage)
            stopifnot(is.character(rejected), grepl("Invalid|finite|retained|common", rejected),
                setequal(names(DSI::datashield.errors()), names(connections)))
            cat("D_INVALID_VECTOR_REJECTED", expression, rejected, "\n")
        }
        for (expression in c("abs(1)", "c(abs(1))")) {
            rejected <- tryCatch(DSI::datashield.assign.expr(connections, "unregistered",
                expression, async = FALSE), error = conditionMessage)
            stopifnot(is.character(rejected),
                grepl("No such DataSHIELD 'ASSIGN' method", rejected, fixed = TRUE),
                grepl("with name: abs", rejected, fixed = TRUE))
            cat("D_UNREGISTERED_ASSIGN_REJECTED", expression, "\n")
        }
        rejected <- tryCatch(DSI::datashield.aggregate(connections, "c(1)", async = FALSE), error = conditionMessage)
        errors <- DSI::datashield.errors() # Raw server messages, without display wrapping.
        stopifnot(is.character(rejected), setequal(names(errors), names(connections)),
            all(vapply(errors, function(x) grepl("No such DataSHIELD 'AGGREGATE' method with name: c",
                x, fixed = TRUE), TRUE)))
        cat("D_AGGREGATE_C_REMAINS_UNREGISTERED\nD_RESTRICTED_ARGUMENT_PROBE_SUCCESS; fitted models 0\n")
    }
    probeD()
}

if (stage == "probe") {
    run <- function() {
        on.exit(DSI::datashield.logout(connections), add = TRUE)
        values <- c(0, -0.12345678901234567, 2^-48, pi, 1 + 2^-52)
        # DSOpal accepts expression text unchanged. Seventeen decimal digits
        # round-trip float64; default deparse() can lose significant digits.
        expression <- paste0("checkPsPrecisionDS(", paste(sprintf("%.17g", values),
            collapse = ", "), ")")
        roundTrip <- DSI::datashield.aggregate(connections, expression, async = FALSE)
        stopifnot(length(roundTrip) == 2L, all(vapply(roundTrip, identical, TRUE, values)))
        cat("FLOAT64_ROUND_TRIP_MAX_ERROR", max(abs(unlist(roundTrip) - rep(values, 2))), "\n")
        DSI::datashield.assign.expr(connections, "input", "loadPsSyntheticDS()", async = FALSE)
        DSI::datashield.assign.expr(connections, "state",
            'initializePsSiteDS(input, "probe")', async = FALSE)
        status <- DSI::datashield.aggregate(connections,
            'getPsSiteStatusDS(state, "probe", 0)', async = FALSE)
        stopifnot(identical(status[[1]]$specification, status[[2]]$specification))
        processes <- lapply(status, function(x) x$process)
        stopifnot(length(unique(vapply(processes, function(x) paste(x$host, x$pid), ""))) == 2L)
        cat("COORDINATOR", unname(Sys.info()["nodename"]), Sys.getpid(), "\n")
        for (name in names(connections)) {
            # OpalConnection's documented opal slot is used only for the public
            # session metadata accessor, never for private execution functions.
            session <- opalr::opal.session_get(connections[[name]]@opal)
            cat("SESSION", name, session$id, processes[[name]]$host, processes[[name]]$pid, "\n")
            print(processes[[name]][c("r", "cyclops", "federatedPs")])
        }
        reference <- readRDS(file.path(work, "probe-reference.rds"))
        likelihood <- sum(vapply(status, function(x) x$logLikelihood, 0.0))
        stopifnot(abs(likelihood - reference$likelihood) <= 1e-10 + 1e-10 * abs(likelihood))
        expression <- sprintf('checkPsSiteConvergenceDS(state, "probe", 0, %.17g)', likelihood)
        DSI::datashield.assign.expr(connections, "state", expression, async = FALSE)
        errors <- c(statistics = 0, increment = 0, bound = 0, coefficient = 0)
        for (j in seq_along(reference$coordinates)) {
            step <- j - 1L
            expression <- sprintf('getPsSiteStatisticsDS(state, "probe", %d, %d)', step, j)
            statistics <- DSI::datashield.aggregate(connections, expression, async = FALSE)
            repeated <- DSI::datashield.aggregate(connections, expression, async = FALSE)
            stopifnot(identical(statistics, repeated))
            total <- Reduce(`+`, lapply(statistics, function(x) x$statistics[1:2]))
            expected <- reference$coordinates[[j]]$statistics[1:2]
            stopifnot(all(abs(total - expected) <= 1e-10 + 1e-10 * pmax(abs(total), abs(expected))))
            errors[["statistics"]] <- max(errors[["statistics"]], abs(total - expected))
            update <- sprintf('updatePsSiteDS(state, "probe", %d, %d, %.17g, %.17g)',
                step, j, total[[1]], total[[2]])
            DSI::datashield.assign.expr(connections[1], "state", update, async = FALSE)
            unchanged <- DSI::datashield.aggregate(connections[2], expression, async = FALSE)
            stopifnot(identical(statistics[2], unchanged))
            DSI::datashield.assign.expr(connections[2], "state", update, async = FALSE)
            status <- DSI::datashield.aggregate(connections,
                sprintf('getPsSiteStatusDS(state, "probe", %d)', j), async = FALSE)
            expected <- reference$coordinates[[j]]$update
            for (site in status) {
                stopifnot(site$initializations == 1L,
                    all(abs(site$update - expected) <= 1e-10 + 1e-10 * pmax(abs(site$update), abs(expected))))
                errors[names(expected)] <- pmax(errors[names(expected)], abs(site$update - expected))
            }
        }
        print(errors)
        saveRDS(list(processes = processes, errors = errors, float64Error = 0),
            file.path(work, "probe-summary.rds"))
        cat("C1_CONNECTION_GATE_SUCCESS\n")
    }
    tryCatch(run(), error = function(e) {
        print(DSI::datashield.errors())
        stop(conditionMessage(e), call. = FALSE)
    })
}

if (stage == "train") {
    train <- function() {
        on.exit(DSI::datashield.logout(connections), add = TRUE)
        # This process reads no fixture/reference files or site-level rows.
        setupStart <- proc.time()[["elapsed"]]
        DSI::datashield.assign.expr(connections, "input", "loadPsSyntheticDS()", async = FALSE)
        sessionIds <- vapply(connections, function(conn) opalr::opal.session_get(conn@opal)$id, "")
        setupSeconds <- proc.time()[["elapsed"]] - setupStart
        runId <- if (isScale) paste0("C2p", scaleP) else "C1fit"
        if (partialTest) {
            # Exercise the real public coordinator's strict default first.
            strict <- tryCatch(fitPsDataShield(connections, "input", "strictLimit"), error = conditionMessage)
            stopifnot(is.character(strict), grepl("did not converge: MAX_ITERATIONS", strict, fixed = TRUE))
            expression <- 'getPsSiteStatusDS(ps_strictLimit, "strictLimit", 8)'
            first <- DSI::datashield.aggregate(connections, expression, async = FALSE)
            second <- DSI::datashield.aggregate(connections, expression, async = FALSE)
            stopifnot(identical(first, second), all(vapply(first, function(x)
                x$model$returnFlag == "MAX_ITERATIONS" && identical(x$model$converged, FALSE) &&
                x$model$iterations == 1L && x$step == 8L, TRUE)))
            reused <- tryCatch(fitPsDataShield(connections, "input", "strictLimit", returnPartial = TRUE), error = conditionMessage)
            stale <- tryCatch(DSI::datashield.aggregate(connections,
                'getPsSiteStatusDS(ps_strictLimit, "strictLimit", 7)', async = FALSE), error = conditionMessage)
            wrong <- tryCatch(DSI::datashield.aggregate(connections,
                'getPsSiteStatusDS(missingSymbol, "strictLimit", 8)', async = FALSE), error = conditionMessage)
            rejected <- tryCatch(DSI::datashield.assign.expr(connections, "ps_strictLimit",
                'updatePsSiteDS(ps_strictLimit, "strictLimit", 8, 1, 0, 1)', async = FALSE), error = conditionMessage)
            stopifnot(is.character(reused), grepl("already exists", reused),
                is.character(stale), grepl("site/run/step", stale), is.character(wrong),
                is.character(rejected), grepl("ready for an update", rejected))
            saveRDS(list(defaultNonconvergenceError = strict, repeatedStatusIdentical = TRUE,
                reusedRunRejected = TRUE, staleRejected = TRUE, wrongSymbolRejected = TRUE,
                postLimitUpdateRejected = TRUE), file.path(work, "partial-contract-summary.rds"))
        }
        # Preserve only session identifiers before a possible external timeout.
        saveRDS(list(sessionIds = sessionIds, runId = runId, termination = "incomplete"),
            file.path(work, "remote.rds"))
        fitStart <- proc.time()[["elapsed"]]
        if (isScale) setTimeLimit(elapsed = c2$remoteSeconds[[as.character(scaleP)]], transient = TRUE)
        result <- tryCatch(fitPsDataShield(connections, "input", runId,
            returnPartial = isScale || partialTest), error = function(e) {
            setTimeLimit(cpu = Inf, elapsed = Inf, transient = FALSE)
            message <- conditionMessage(e)
            timedOut <- isScale && grepl("reached elapsed time limit", message, fixed = TRUE)
            if (!timedOut) stop(e)
            list(termination = "time_limit", error = message)
        })
        setTimeLimit(cpu = Inf, elapsed = Inf, transient = FALSE)
        result$fitWallSeconds <- proc.time()[["elapsed"]] - fitStart
        if (is.null(result$termination)) result$termination <-
            if (result$model$returnFlag == "SUCCESS") "converged" else "pilot_complete"
        result$trainingEndedAt <- format(Sys.time(), "%Y-%m-%dT%H:%M:%OS6Z", tz = "UTC")
        result$setupSeconds <- setupSeconds
        result$coordinator <- list(host = unname(Sys.info()["nodename"]), pid = Sys.getpid(),
            r = R.version.string, federatedPs = find.package("FederatedPs"))
        result$sessionIds <- sessionIds
        result$runId <- runId
        # Preserve the plain fit result even if later site evaluation fails.
        saveRDS(result, file.path(work, "remote.rds"))
        if (result$termination == "time_limit") {
            print(result[c("termination", "fitWallSeconds", "initializationSeconds", "trainingSeconds", "error", "stateQueryError")])
            return(invisible(NULL))
        }
        stopifnot(all(vapply(result$processes, function(x) identical(x$returnPartialDefault, FALSE), TRUE)))
        result$verificationCallsPerSite <- 2L
        if (isScale || partialTest) {
            expression <- sprintf('getPsSiteStatusDS(%s, "%s", %d)', result$stateSymbol, result$runId, result$step)
            first <- DSI::datashield.aggregate(connections, expression, async = FALSE)
            second <- DSI::datashield.aggregate(connections, expression, async = FALSE)
            stopifnot(identical(first, second))
            result$terminalQueriesIdentical <- TRUE
            result$verificationCallsPerSite <- 4L
        }
        DSI::datashield.assign.expr(connections, result$stateSymbol,
            sprintf('evaluatePsSiteDS(%s, input, "%s", %d)', result$stateSymbol, result$runId, result$step),
            async = FALSE)
        result$evaluations <- DSI::datashield.aggregate(connections,
            sprintf('getPsSiteEvaluationDS(%s, "%s", %d)', result$stateSymbol, result$runId, result$step),
            async = FALSE)
        saveRDS(result, file.path(work, "remote.rds"))
        cat("REMOTE_FIT", result$termination, result$step, "coordinate cycles", length(result$sweepSeconds), "sweeps\n")
        print(result$model[c("iterations", "returnFlag", "objective")])
        print(result$calls)
        print(c(initializationSeconds = result$initializationSeconds, trainingSeconds = result$trainingSeconds,
            medianCycleSeconds = stats::median(result$coordinates[, "seconds"]),
            medianSweepSeconds = stats::median(result$sweepSeconds)))
    }
    train()
}

if (stage == "compare" && !isScale && !partialTest) {
    # A separate synthetic evaluator may read plain references. It never drives
    # the training loop, and no reference/native pointer is restored.
    baseline <- readRDS(file.path(work, "reference.rds"))
    simulation <- readRDS(file.path(work, "simulation.rds"))
    remote <- readRDS(file.path(work, "remote.rds"))
    stopifnot(length(remote$evaluations) == 2L)
    expected <- readRDS(file.path(work, "coordinate-reference.rds"))
    tolerance <- baseline$settings$tolerance
    coordinateTolerance <- c(absolute = 1e-10, relative = 1e-10)
    actual <- remote$coordinates[, colnames(expected), drop = FALSE]
    stopifnot(identical(dim(actual), dim(expected)), all(is.finite(c(actual, expected))))
    difference <- abs(actual - expected)
    stopifnot(all(difference <= coordinateTolerance[[1]] + coordinateTolerance[[2]] * pmax(abs(actual), abs(expected))))
    modelReferences <- list(reference = baseline$results$pooled$models$global,
        simulation = simulation$models$global)
    objectiveErrors <- vapply(modelReferences, function(model) {
        a <- remote$model$objective
        b <- model$objective
        stopifnot(abs(a - b) <= tolerance[[1]] + tolerance[[2]] * max(abs(a), abs(b)),
            remote$model$iterations == model$iterations,
            all(abs(remote$model$coefficients - model$coefficients) <=
                tolerance[[1]] + tolerance[[2]] * pmax(abs(remote$model$coefficients), abs(model$coefficients))))
        abs(a - b)
    }, 0.0)
    stopifnot(all(remote$initializations == 1L), remote$model$returnFlag == "SUCCESS")
    evaluations <- lapply(remote$evaluations, function(x) x$evaluation)
    summary <- do.call(rbind, lapply(evaluations, function(x) x$summary))
    result <- list(coordinateErrors = apply(difference, 2L, max), objectiveErrors = objectiveErrors,
        rawPsErrors = lapply(evaluations, function(x) x$rawPsErrors), summary = summary,
        balanceMeanErrors = vapply(evaluations, function(x) x$balanceMeanError, 0.0),
        pooledRemotePairsEqual = vapply(evaluations, function(x) x$pooledRemotePairsEqual, TRUE))
    print(result$coordinateErrors)
    print(result$objectiveErrors)
    print(result$rawPsErrors)
    print(summary, row.names = FALSE, digits = 9)
    print(result$pooledRemotePairsEqual)
    saveRDS(result, file.path(work, "comparison-summary.rds"))
    cat("C1_NUMERICAL_AND_OHDSI_COMPARISON_SUCCESS\n")
}

if (stage == "compare" && (isScale || partialTest)) {
    # Independent synthetic evaluator; no worker data are returned to training.
    baseline <- readRDS(file.path(work, "reference.rds"))
    simulationFile <- file.path(work, "simulation.rds")
    simulation <- if (file.exists(simulationFile)) readRDS(simulationFile) else NULL
    remote <- readRDS(file.path(work, "remote.rds"))
    pilot <- readRDS(file.path(work, "pilot-reference.rds"))
    summarizeError <- function(a, b, tolerance) {
        stopifnot(length(a) == length(b), length(a) > 0L, all(is.finite(c(a, b))))
        difference <- abs(a - b)
        ratio <- difference / (tolerance[[1L]] + tolerance[[2L]] * pmax(abs(a), abs(b)))
        stopifnot(all(ratio <= 1))
        c(absolute = max(difference), toleranceRatio = max(ratio))
    }
    stopifnot(remote$termination %in% c("converged", "pilot_complete"),
        remote$model$returnFlag == pilot$returnFlag, remote$model$iterations == pilot$sweeps,
        length(remote$sweepSeconds) == pilot$sweeps,
        remote$step == pilot$sweeps * length(pilot$coefficients),
        nrow(remote$coordinates) == remote$step, all(remote$initializations == 1L),
        isTRUE(remote$terminalQueriesIdentical))
    if (remote$termination == "pilot_complete") stopifnot(identical(remote$model$converged, FALSE))
    expected <- readRDS(file.path(work, "coordinate-reference.rds"))
    actual <- remote$coordinates[, colnames(expected), drop = FALSE]
    stopifnot(identical(dim(actual), dim(expected)))
    coordinateErrors <- vapply(colnames(expected), function(name)
        summarizeError(actual[, name], expected[, name], c2$coordinateTolerance),
        c(absolute = 0.0, toleranceRatio = 0.0))
    coefficient <- summarizeError(remote$model$coefficients, pilot$coefficients, c2$coordinateTolerance)
    bound <- summarizeError(tail(actual[, "bound"], length(pilot$coefficients)),
        pilot$bounds, c2$coordinateTolerance)
    objective <- summarizeError(remote$model$objective, pilot$objective, c2$tolerance)
    evaluations <- lapply(remote$evaluations, function(x) x$evaluation)
    stopifnot(length(evaluations) == 2L, all(vapply(evaluations, function(x)
        isTRUE(x$statusUnchanged) && isTRUE(x$nativePredictionUnchanged) &&
        identical(x$matchingPerformed, FALSE), TRUE)))
    predictionErrors <- Reduce(pmax, lapply(evaluations, function(x) x$errors))
    stopifnot(all(predictionErrors["toleranceRatio", ] <= 1))
    errors <- list(remote = c(objective = objective[[1]], objectiveRatio = objective[[2]],
        rawPs = predictionErrors["absolute", "rawPs"],
        rawPsRatio = predictionErrors["toleranceRatio", "rawPs"],
        linearPredictor = predictionErrors["absolute", "linearPredictor"],
        linearPredictorRatio = predictionErrors["toleranceRatio", "linearPredictor"],
        coefficients = coefficient[[1]], coefficientRatio = coefficient[[2]],
        finalBound = bound[[1]], finalBoundRatio = bound[[2]]),
        coordinates = coordinateErrors["absolute", ],
        coordinateRatios = coordinateErrors["toleranceRatio", ],
        liveNativePrediction = predictionErrors, sameSweep = TRUE)
    if (!is.null(simulation)) {
        reference <- baseline$results$pooled
        objective <- summarizeError(simulation$models$global$objective,
            reference$models$global$objective, c2$tolerance)
        ps <- vapply(names(simulation$populations), function(name) {
            a <- simulation$populations[[name]]; b <- reference$populations[[name]]
            stopifnot(identical(a$rowId, b$rowId))
            summarizeError(a$propensityScore, b$propensityScore, c2$tolerance)
        }, c(absolute = 0.0, toleranceRatio = 0.0))
        errors$simulation <- c(objective = objective[[1]], objectiveRatio = objective[[2]],
            rawPs = max(ps["absolute", ]), rawPsRatio = max(ps["toleranceRatio", ]))
    }
    if (remote$model$returnFlag == "SUCCESS") {
        model <- baseline$results$pooled$models$global
        errors$remoteFinalObjective <- summarizeError(remote$model$objective, model$objective, c2$tolerance)
        errors$remoteFinalCoefficients <- summarizeError(remote$model$coefficients, model$coefficients, c2$tolerance)
    }
    print(errors)
    saveRDS(errors, file.path(work, "comparison-summary.rds"))
    cat("SAME_SWEEP_COMPARISON", if (partialTest) "small" else scaleP, remote$termination, "\n")
}

if (stage == "failures") {
    failures <- function() {
        on.exit(DSI::datashield.logout(connections), add = TRUE)
        DSI::datashield.assign.expr(connections, "input", "loadPsSyntheticDS()", async = FALSE)
        DSI::datashield.assign.expr(connections, "ps_fault", 'initializePsSiteDS(input, "fault")', async = FALSE)
        reused <- tryCatch(fitPsDataShield(connections, "input", "fault", returnPartial = TRUE), error = conditionMessage)
        stopifnot(is.character(reused), grepl("Run state already exists", reused))
        status <- DSI::datashield.aggregate(connections, 'getPsSiteStatusDS(ps_fault, "fault", 0)', async = FALSE)
        likelihood <- sum(vapply(status, function(x) x$logLikelihood, 0.0))
        DSI::datashield.assign.expr(connections, "ps_fault",
            sprintf('checkPsSiteConvergenceDS(ps_fault, "fault", 0, %.17g)', likelihood), async = FALSE)
        values <- DSI::datashield.aggregate(connections, 'getPsSiteStatisticsDS(ps_fault, "fault", 0, 1)', async = FALSE)
        total <- Reduce(`+`, lapply(values, function(x) x$statistics[1:2]))
        expression <- sprintf('updatePsSiteDS(ps_fault, "fault", 0, 1, %.17g, %.17g)', total[[1]], total[[2]])
        DSI::datashield.assign.expr(connections[1], "ps_fault", expression, async = FALSE)
        duplicate <- tryCatch(DSI::datashield.assign.expr(connections[1], "ps_fault", expression, async = FALSE),
            error = conditionMessage)
        stopifnot(is.character(duplicate), grepl("stale, duplicate", duplicate))
        unaffected <- DSI::datashield.aggregate(connections[2], 'getPsSiteStatusDS(ps_fault, "fault", 0)', async = FALSE)
        stopifnot(unaffected[[1]]$step == 0)
        DSI::datashield.assign.expr(connections, "nonfinite", 'initializePsSiteDS(input, "nonfinite")', async = FALSE)
        status <- DSI::datashield.aggregate(connections, 'getPsSiteStatusDS(nonfinite, "nonfinite", 0)', async = FALSE)
        likelihood <- sum(vapply(status, function(x) x$logLikelihood, 0.0))
        DSI::datashield.assign.expr(connections, "nonfinite",
            sprintf('checkPsSiteConvergenceDS(nonfinite, "nonfinite", 0, %.17g)', likelihood), async = FALSE)
        nonfinite <- tryCatch(DSI::datashield.assign.expr(connections[1], "nonfinite",
            'updatePsSiteDS(nonfinite, "nonfinite", 0, 1, 1e309, 1)', async = FALSE), error = conditionMessage)
        stopifnot(is.character(nonfinite), grepl("finite", nonfinite))
        # A separate explicit test run exercises partial application followed by
        # session loss. The failed duplicate run is never resumed.
        DSI::datashield.assign.expr(connections, "termination", 'initializePsSiteDS(input, "termination")', async = FALSE)
        status <- DSI::datashield.aggregate(connections, 'getPsSiteStatusDS(termination, "termination", 0)', async = FALSE)
        likelihood <- sum(vapply(status, function(x) x$logLikelihood, 0.0))
        DSI::datashield.assign.expr(connections, "termination",
            sprintf('checkPsSiteConvergenceDS(termination, "termination", 0, %.17g)', likelihood), async = FALSE)
        values <- DSI::datashield.aggregate(connections, 'getPsSiteStatisticsDS(termination, "termination", 0, 1)', async = FALSE)
        total <- Reduce(`+`, lapply(values, function(x) x$statistics[1:2]))
        expression <- sprintf('updatePsSiteDS(termination, "termination", 0, 1, %.17g, %.17g)', total[[1]], total[[2]])
        DSI::datashield.assign.expr(connections[1], "termination", expression, async = FALSE)
        beforeLoss <- DSI::datashield.aggregate(connections[1], 'getPsSiteStatusDS(termination, "termination", 1)', async = FALSE)
        # Delete exactly this test session with the public endpoint used by
        # opal.session_delete(), retaining the client's now-stale session ID.
        # The high-level delete clears that ID and would permit a new session.
        id <- opalr::opal.session_get(connections[[2]]@opal)$id
        invisible(opalr::opal.delete(connections[[2]]@opal, "datashield", "session", id))
        terminated <- tryCatch(DSI::datashield.assign.expr(connections[2], "termination", expression, async = FALSE),
            error = conditionMessage)
        stopifnot(is.character(terminated), grepl("404|Not Found", terminated),
            !opalr::opal.session_exists(connections[[2]]@opal))
        afterLoss <- DSI::datashield.aggregate(connections[1], 'getPsSiteStatusDS(termination, "termination", 1)', async = FALSE)
        stopifnot(identical(beforeLoss, afterLoss))
        blocked <- tryCatch(fitPsDataShield(connections, "input", "AfterTermination", returnPartial = TRUE), error = conditionMessage)
        stopifnot(is.character(blocked), grepl("session is unavailable", blocked))
        saveRDS(list(reusedRunRejected = TRUE, duplicateRejected = TRUE, terminatedRejected = TRUE, closedRunRejected = TRUE,
            nonfiniteRejected = TRUE, partialWorkerLossRejected = TRUE,
            duplicate = duplicate, terminated = terminated), file.path(work, "failure-summary.rds"))
        cat("C1_DUPLICATE_AND_SESSION_TERMINATION_SUCCESS\n")
    }
    failures()
}

if (stage == "audit") {
    isD <- file.exists(file.path(work, "d-remote.rds"))
    remote <- readRDS(file.path(work, if (isD) "d-remote.rds" else "remote.rds"))
    administrator <- opalr::opal.login(username = "administrator",
        password = Sys.getenv("C1_OPAL_PASSWORD"), url = "https://localhost:8443")
    log <- opalr::dsadmin.log(administrator)
    restPath <- file.path(work, "opal-rest.log")
    invisible(opalr::opal.get(administrator, "system", "log", "rest.log",
        acceptType = "text/plain", query = list(all = TRUE), outFile = restPath))
    rest <- readLines(restPath, warn = FALSE)
    counts <- lapply(names(remote$sessionIds), function(site) {
        id <- remote$sessionIds[[site]]
        entries <- log[!is.na(log$ds_id) & log$ds_id == id, ]
        # Count the actual per-request JSON audit lines addressing this session.
        # PARSE and ASSIGN/AGGREGATE are separate log events for one request.
        requests <- rest[grepl(paste0('/datashield/session/', id), rest, fixed = TRUE)]
        requestTimes <- as.POSIXct(sub('.*"@timestamp":"([^"]+)".*', '\\1', requests),
            format = "%Y-%m-%dT%H:%M:%OSZ", tz = "UTC")
        trainingEnd <- as.POSIXct(remote$trainingEndedAt, format = "%Y-%m-%dT%H:%M:%OSZ", tz = "UTC")
        initialization <- sum(entries$ds_action == "ASSIGN" &
            grepl("initializePsSiteDS", entries$ds_eval, fixed = TRUE), na.rm = TRUE)
        stopifnot(initialization == if (isD) length(remote$fits) else 1L)
        updates <- entries[entries$ds_action == "ASSIGN" &
            grepl("updatePsSiteDS", entries$ds_eval, fixed = TRUE), ]
        if (isD) stopifnot(nrow(updates) == sum(vapply(remote$fits, function(x) x$step, 0L)))
        updateTimes <- as.numeric(as.POSIXct(updates[["@timestamp"]],
            format = "%Y-%m-%dT%H:%M:%OSZ", tz = "UTC"))
        spacing <- diff(updateTimes)
        stopifnot(length(spacing) > 0L, all(is.finite(spacing)), all(spacing >= 0))
        data.frame(site = site, httpRequests = length(requests),
            httpThroughTraining = if (all(!is.na(requestTimes))) sum(requestTimes <= trainingEnd) else NA_integer_,
            httpAfterTraining = if (all(!is.na(requestTimes))) sum(requestTimes > trainingEnd) else NA_integer_,
            get = sum(grepl('"method":"GET"', requests, fixed = TRUE)),
            put = sum(grepl('"method":"PUT"', requests, fixed = TRUE)),
            post = sum(grepl('"method":"POST"', requests, fixed = TRUE)),
            delete = sum(grepl('"method":"DELETE"', requests, fixed = TRUE)),
            assign = sum(entries$ds_action == "ASSIGN"),
            aggregate = sum(entries$ds_action == "AGGREGATE"), initializations = initialization,
            updateAssignments = nrow(updates),
            updateLogSpacingMedian = median(spacing), updateLogSpacingMin = min(spacing),
            updateLogSpacingMax = max(spacing))
    })
    counts <- do.call(rbind, counts)
    print(counts, row.names = FALSE)
    saveRDS(counts, file.path(work, "request-summary.rds"))
    opalr::opal.logout(administrator)
    cat(if (isD) "D" else "C1", "REQUEST_AUDIT_SUCCESS; network bytes unmeasured\n")
}

if (stage == "scaleSummary") {
    rows <- list()
    for (p in c2$dimensions) {
        path <- file.path(work, paste0("p", p))
        readResult <- function(name) {
            file <- file.path(path, paste0(name, ".rds"))
            if (file.exists(file)) readRDS(file) else NULL
        }
        fixture <- readResult("fixture")
        metadata <- readResult("metadata")
        if (is.null(metadata)) metadata <- list(actualP = length(unique(unlist(lapply(fixture$sites,
            function(site) site$covariates$covariateId)))),
            nnz = vapply(fixture$sites, function(site) nrow(site$covariates), 0L),
            sparseBytes = c(NA_real_, NA_real_))
        reference <- readResult("reference")
        simulation <- readResult("simulation")
        remote <- readResult("remote")
        pilot <- readResult("pilot-reference")
        audit <- readResult("request-summary")
        errors <- readResult("comparison-summary")
        for (method in c("reference", "simulation", "pooled1state", "remote")) {
            result <- switch(method, reference = reference, simulation = simulation,
                pooled1state = if (is.null(pilot)) NULL else list(fitSeconds = pilot$seconds, prepareSeconds = NA_real_),
                remote = remote)
            model <- switch(method, reference = reference$results$pooled$models$global,
                simulation = simulation$models$global,
                pooled1state = if (is.null(pilot)) NULL else list(iterations = pilot$sweeps, returnFlag = pilot$returnFlag),
                remote = remote$model)
            remoteMethod <- method == "remote"
            observedCycles <- if (!is.null(model)) model$iterations * (metadata$actualP + 1L) else
                if (remoteMethod && !is.null(audit) && length(unique(audit$updateAssignments)) == 1L)
                    audit$updateAssignments[[1L]] else NA_real_
            status <- if (is.null(result)) "not_run" else if (!is.null(model))
                if (model$returnFlag == "SUCCESS") "converged" else "pilot_complete" else result$termination
            errorValue <- function(name) {
                values <- errors[[method]]
                if (is.null(values) || !name %in% names(values)) NA_real_ else values[[name]]
            }
            row <- data.frame(scenario = paste0("S", match(p, c2$dimensions)), method = method,
                seed = c2$seed, n = sum(c2$sizes), n_site1 = c2$sizes[[1]], n_site2 = c2$sizes[[2]],
                target_site1 = sum(fixture$sites$site1$population$treatment),
                target_site2 = sum(fixture$sites$site2$population$treatment),
                nominal_p = p, nonzero_candidate_p = metadata$actualP, coordinates = metadata$actualP + 1L,
                nnz_site1 = metadata$nnz[[1]], nnz_site2 = metadata$nnz[[2]],
                sparse_bytes_site1 = metadata$sparseBytes[[1]], sparse_bytes_site2 = metadata$sparseBytes[[2]],
                prior_variance = 1, initial_coefficient = 0, lange_tolerance = 1e-12,
                fit_atol = c2$tolerance[[1]], fit_rtol = c2$tolerance[[2]],
                coordinate_atol = c2$coordinateTolerance[[1]], coordinate_rtol = c2$coordinateTolerance[[2]],
                scope = if (method %in% c("remote", "pooled1state") && p != 100L)
                    paste(c2$remoteSweeps[[as.character(p)]], "sweep pilot") else "convergence attempt",
                time_cap_seconds = if (remoteMethod) c2$remoteSeconds[[as.character(p)]] else c2$localSeconds,
                completed_sweeps = floor(observedCycles / (metadata$actualP + 1L)), completed_cycles = observedCycles,
                termination = status, native_status = if (is.null(model)) NA_character_ else model$returnFlag,
                converged = if (is.null(model)) NA else model$returnFlag == "SUCCESS",
                numerical_check = if (method %in% c("reference", "pooled1state")) "reference" else
                    if (!is.null(errors[[method]])) "pass" else "not_verified",
                prepare_seconds = if (!remoteMethod && !is.null(result)) result$prepareSeconds else NA_real_,
                initialization_seconds = if (remoteMethod && !is.null(result$initializationSeconds)) result$initializationSeconds else NA_real_,
                fit_wall_seconds = if (is.null(result)) NA_real_ else
                    if (remoteMethod) { if (is.null(result$fitWallSeconds)) NA_real_ else result$fitWallSeconds } else result$fitSeconds,
                training_seconds = if (remoteMethod && !is.null(result$trainingSeconds)) result$trainingSeconds else NA_real_,
                cycle_median_seconds = if (remoteMethod && !is.null(result$coordinates)) median(result$coordinates[, "seconds"]) else NA_real_,
                cycle_min_seconds = if (remoteMethod && !is.null(result$coordinates)) min(result$coordinates[, "seconds"]) else NA_real_,
                cycle_max_seconds = if (remoteMethod && !is.null(result$coordinates)) max(result$coordinates[, "seconds"]) else NA_real_,
                sweep_median_seconds = if (remoteMethod && !is.null(result$sweepSeconds)) median(result$sweepSeconds) else NA_real_,
                http_site1 = if (remoteMethod && !is.null(audit)) audit$httpRequests[[1]] else NA_integer_,
                http_site2 = if (remoteMethod && !is.null(audit)) audit$httpRequests[[2]] else NA_integer_,
                http_through_training_per_site = if (remoteMethod && !is.null(audit)) audit$httpThroughTraining[[1]] else NA_integer_,
                http_after_training_per_site = if (remoteMethod && !is.null(audit)) audit$httpAfterTraining[[1]] else NA_integer_,
                verification_calls_per_site = if (remoteMethod && !is.null(result$verificationCallsPerSite)) result$verificationCallsPerSite else NA_integer_,
                update_log_spacing_median_seconds = if (remoteMethod && !is.null(audit$updateLogSpacingMedian)) audit$updateLogSpacingMedian[[1]] else NA_real_,
                update_log_spacing_min_seconds = if (remoteMethod && !is.null(audit$updateLogSpacingMin)) audit$updateLogSpacingMin[[1]] else NA_real_,
                update_log_spacing_max_seconds = if (remoteMethod && !is.null(audit$updateLogSpacingMax)) audit$updateLogSpacingMax[[1]] else NA_real_,
                logical_calls_per_site = if (remoteMethod && !is.null(result$calls)) sum(result$calls[1, ]) else NA_integer_,
                native_initializations_site1 = if (remoteMethod && !is.null(audit)) audit$initializations[[1]] else NA_integer_,
                native_initializations_site2 = if (remoteMethod && !is.null(audit)) audit$initializations[[2]] else NA_integer_,
                objective_error = if (!is.null(errors[[method]])) errors[[method]][["objective"]] else NA_real_,
                raw_ps_error = if (!is.null(errors[[method]])) errors[[method]][["rawPs"]] else NA_real_,
                objective_tolerance_ratio = errorValue("objectiveRatio"),
                raw_ps_tolerance_ratio = errorValue("rawPsRatio"),
                linear_predictor_error = errorValue("linearPredictor"),
                linear_predictor_tolerance_ratio = errorValue("linearPredictorRatio"),
                coefficient_error = errorValue("coefficients"),
                coefficient_tolerance_ratio = errorValue("coefficientRatio"),
                coordinate_max_tolerance_ratio = if (remoteMethod && !is.null(errors$coordinateRatios)) max(errors$coordinateRatios) else NA_real_,
                cache_max_tolerance_ratio = if (remoteMethod && !is.null(errors$liveNativePrediction))
                    max(errors$liveNativePrediction["toleranceRatio", c("cacheRawPs", "cacheLinearPredictor")]) else NA_real_,
                gradient_error = if (remoteMethod && !is.null(errors$coordinates)) errors$coordinates[["gradient"]] else NA_real_,
                curvature_error = if (remoteMethod && !is.null(errors$coordinates)) errors$coordinates[["curvature"]] else NA_real_,
                increment_error = if (remoteMethod && !is.null(errors$coordinates)) errors$coordinates[["increment"]] else NA_real_,
                bound_error = if (remoteMethod && !is.null(errors$coordinates)) errors$coordinates[["bound"]] else NA_real_,
                network_bytes = NA_real_, container_memory_bytes = NA_real_,
                note = if (remoteMethod && !is.null(result$stateQueryError))
                    "MAX_ITERATIONS marked worker failed; intermediate state and timing unavailable" else
                    if (is.null(result)) "not executed" else "")
            rows[[length(rows) + 1L]] <- row
        }
    }
    summary <- do.call(rbind, rows)
    pilot <- file.path(work, "p1000", "remote.rds")
    if (file.exists(pilot) && !is.null(readRDS(pilot)$stateQueryError)) {
        summary$note[summary$termination == "not_run"] <- "Not run: current pilot API blocks intermediate-state validation"
    }
    memoryFile <- file.path(work, "memory-samples.csv")
    if (file.exists(memoryFile)) {
        memory <- utils::read.csv(memoryFile)
        for (role in c("coordinator", "rock1", "rock2")) {
            summary[[paste0(role, "_rss_kib_sample")]] <- vapply(seq_len(nrow(summary)), function(i) {
                selected <- memory$rssKiB[memory$scenario == summary$scenario[i] & memory$role == role]
                if (summary$method[i] != "remote" || !length(selected)) NA_real_ else max(selected)
            }, 0.0)
        }
    }
    utils::write.csv(summary, file.path(work, "scale-summary.csv"), row.names = FALSE, na = "NA")
    print(summary[, c("scenario", "method", "completed_sweeps", "fit_wall_seconds", "termination", "numerical_check")], row.names = FALSE)
}

if (stage %in% c("convergenceInput", "convergenceCheck", "convergenceCompare")) {
    Sys.setenv(FEDERATEDPS_SETUP_ONLY = "true")
    setwd(sourcePath)
    definitions <- new.env()
    sys.source(file.path(sourcePath, "tests/testthat/test-preprocessing-cv.R"), definitions)
    if (stage == "convergenceInput") {
        fixture <- definitions$dFixture()
        local <- fixture
        local$sites <- fixture$sites["site1"]
        input <- definitions$dOracle(local, inputOnly = TRUE)
        worker <- preparePsCvDS(definitions$dInputs(local)[[1L]], 2L, 20260907L)
        summary <- combinePsSummaries(list(site1 = getPsPreprocessingDS(worker, 1L)), 0.05)
        transformed <- applyPsPreprocessingDS(worker, 1L, summary$covariateIds, summary$scales)
        transformError <- max(abs(transformed$preparedSite$x - input$matrices$site1$train))
        stopifnot(transformError <= definitions$dSettings$scaleTolerance[["absolute"]])
        stopifnot(identical(unname(worker$foldId), unname(input$folds$site1)),
            identical(rownames(transformed$preparedSite$x), input$training$site1),
            identical(colnames(transformed$preparedSite$x), colnames(input$x)),
            identical(unname(transformed$preparedSite$y), unname(input$y)),
            identical(summary$covariateIds, input$specification$covariateIds),
            identical(summary$excludedIds, input$specification$excludedIds),
            identical(summary$scales, input$specification$scales),
            identical(transformed$settings$startingCoefficients, input$initial),
            identical(transformed$settings$control, input$control))
        Andromeda::close(worker$raw$cohortMethodData)
        saveRDS(input, file.path(work, "convergence-input.rds"))
        saveRDS(fixture, file.path(work, "unchanged-fixture.rds"))
        cat("INDEPENDENT_ORACLE_WORKER_INPUT_VERIFIED", nrow(input$x), ncol(input$x),
            "target", sum(input$y), "comparator", sum(input$y == 0),
            "transform_error", transformError, "\n")
    } else if (stage == "convergenceCheck") {
        kind <- Sys.getenv("CYCLOPS_LANGE_BUILD")
        stopifnot(kind %in% c("U", "A", "L", "F"))
        input <- readRDS(file.path(work, "convergence-input.rds"))
        prior <- Cyclops::createPrior("laplace", variance = input$variance,
            exclude = "(Intercept)", useCrossValidation = FALSE)
        control <- do.call(Cyclops::createControl, input$control)
        data <- Cyclops::createCyclopsData(y ~ 1,
            data = data.frame(y = unname(input$y), row.names = rownames(input$x)),
            sx = input$x, modelType = "lr", floatingPoint = 64)
        data$coefficientNames <- names(input$initial)
        fit <- Cyclops::fitCyclopsModel(data, prior, control,
            startingCoefficients = unname(input$initial))
        # Only this independent diagnostic reads an error fit's coefficients.
        beta <- stats::coef(fit, ignoreConvergence = fit$return_flag != "SUCCESS")
        before <- definitions$dKkt(input$x, input$y, input$initial, input$variance)
        after <- definitions$dKkt(input$x, input$y, beta, input$variance)
        prediction <- stats::predict(fit)
        # gradient() has no ignoreConvergence option; preserve that guard on U.
        nativeGradient <- if (fit$return_flag == "SUCCESS") -unname(Cyclops::gradient(fit)) else NULL
        stopifnot(max(before$ratio) <= 1, max(after$ratio) <= 1,
            is.null(nativeGradient) || all(abs(nativeGradient - after$gradient) <= 1e-10 + 1e-10 * abs(after$gradient)),
            max(abs(prediction - after$ps)) <= 1e-7,
            abs(fit$log_likelihood - after$logLikelihood) <= 1e-7,
            abs(fit$log_prior - after$logPrior) <= 1e-7,
            identical(unname(beta), unname(input$initial)))
        result <- list(build = kind, status = fit$return_flag, iterations = fit$iterations,
            initial = input$initial, beta = beta, before = before, after = after,
            nativeGradientError = if (is.null(nativeGradient)) NA_real_ else max(abs(nativeGradient - after$gradient)),
            cacheError = max(abs(prediction - after$ps)),
            target = sum(input$y), comparator = sum(input$y == 0),
            interceptOnly = log(mean(input$y) / (1 - mean(input$y))),
            library = find.package("Cyclops"), native = getLoadedDLLs()[["Cyclops"]][["path"]])
        if (kind %in% c("A", "F")) {
            state <- Cyclops::initializeCyclopsCoordinateDescent(input$y, input$x, prior, control, input$initial)
            initialFit <- Cyclops::getCyclopsCoordinateFit(state)
            stopifnot(!Cyclops::checkCyclopsCoordinateConvergence(state, initialFit$log_likelihood))
            trace <- matrix(NA_real_, length(beta), 5L,
                dimnames = list(names(beta), c("gradient", "curvature", "increment", "coefficient", "bound")))
            for (j in seq_along(beta)) {
                values <- Cyclops::getCyclopsCoordinateStatistics(state, names(beta)[j])
                change <- Cyclops::updateCyclopsCoordinate(state, names(beta)[j], values[[1L]], values[[2L]])
                trace[j, ] <- c(values[1:2], change)
            }
            snapshot <- Cyclops::getCyclopsCoordinateFit(state)
            stopifnot(Cyclops::checkCyclopsCoordinateConvergence(state, snapshot$log_likelihood))
            snapshot <- Cyclops::getCyclopsCoordinateFit(state)
            stopifnot(identical(snapshot$return_flag, fit$return_flag), snapshot$iterations == 1L,
                all(trace[, "increment"] == 0), all(trace[, "coefficient"] == input$initial),
                max(abs(trace[, "gradient"] - before$gradient)) <= 1e-10,
                max(abs(stats::predict(snapshot) - before$ps)) <= 1e-7)
            result$coordinateTrace <- trace
            result$nativeGradientError <- max(abs(trace[, "gradient"] - before$gradient))
            result$objectiveChange <- -(snapshot$log_likelihood + snapshot$log_prior) +
                (initialFit$log_likelihood + initialFit$log_prior)
        }
        saveRDS(result, file.path(work, paste0("convergence-", kind, ".rds")))
        print(list(build = kind, status = result$status, iterations = result$iterations,
            target = result$target, comparator = result$comparator, lambda = sqrt(2 / input$variance),
            initialKkt = max(before$residual), finalKkt = max(after$residual),
            initialKktRatio = max(before$ratio), finalKktRatio = max(after$ratio),
            gradient = before$gradient, objective = after$objective,
            maxIncrement = if (is.null(result$coordinateTrace)) NA_real_ else max(abs(result$coordinateTrace[, "increment"])),
            objectiveChange = result$objectiveChange, cacheError = result$cacheError,
            library = result$library, native = result$native))
    } else {
        values <- lapply(c("U", "A", "L", "F"), function(kind) readRDS(file.path(work, paste0("convergence-", kind, ".rds"))))
        stopifnot(identical(vapply(values, function(x) x$status, ""),
            c("POOR_BLR_STEP", "POOR_BLR_STEP", "SUCCESS", "SUCCESS")))
        summary <- do.call(rbind, lapply(values, function(x) data.frame(build = x$build, status = x$status,
            iterations = x$iterations, target = x$target, comparator = x$comparator,
            maxBetaChange = max(abs(x$beta - x$initial)), objective = x$after$objective,
            objectiveErrorVsU = abs(x$after$objective - values[[1L]]$after$objective),
            maxInitialKkt = max(x$before$residual), maxFinalKkt = max(x$after$residual),
            maxInitialKktRatio = max(x$before$ratio), maxFinalKktRatio = max(x$after$ratio),
            gradientError = x$nativeGradientError, nativeCacheError = x$cacheError,
            maxIncrement = if (is.null(x$coordinateTrace)) NA_real_ else max(abs(x$coordinateTrace[, "increment"])),
            library = x$library, nativeLibrary = x$native)))
        stopifnot(all(summary$objectiveErrorVsU <= 1e-7), all(summary$maxBetaChange == 0))
        utils::write.csv(summary, file.path(work, "convergence-validation.csv"), row.names = FALSE)
        print(summary)
        unmodified <- readRDS(file.path(work, "coordinate-U.rds"))
        corrected <- readRDS(file.path(work, "coordinate-L.rds"))
        stopifnot(identical(unmodified$settings, corrected$settings),
            identical(unmodified$fixtures, corrected$fixtures))
        for (i in seq_along(unmodified$results)) {
            a <- unmodified$results[[i]]; b <- corrected$results[[i]]
            stopifnot(identical(a$status, b$status), identical(a$iterations, b$iterations),
                identical(a$warnings, b$warnings))
            for (field in c("beta", "eta", "ps", "objective")) {
                error <- abs(a[[field]] - b[[field]])
                ratio <- error / (1e-7 + 1e-7 * pmax(abs(a[[field]]), abs(b[[field]])))
                stopifnot(all(ratio <= 1))
                cat("U_L_SUCCESS_REGRESSION", unmodified$fixtures[[i]]$name, field,
                    "maxAbsolute", max(error), "maxToleranceRatio", max(ratio), "\n")
            }
        }
    }
}

if (stage %in% c("dReference", "dSetup")) {
    Sys.setenv(FEDERATEDPS_SETUP_ONLY = "true")
    setwd(sourcePath)
    definitions <- new.env()
    sys.source(file.path(sourcePath, "tests/testthat/test-preprocessing-cv.R"), definitions)
    fixture <- definitions$dFixture()
    settings <- definitions$dSettings
    if (stage == "dReference") {
        stopifnot(find.package("Cyclops") == "/opt/federatedps/corrected-reference-library/Cyclops",
            !"initializeCyclopsCoordinateDescent" %in% getNamespaceExports("Cyclops"))
        started <- proc.time()[["elapsed"]]
        pooled <- definitions$dOracle(fixture)
        local <- lapply(names(fixture$sites), function(name) {
            subset <- fixture
            subset$sites <- subset$sites[name]
            definitions$dOracle(subset)
        })
        names(local) <- names(fixture$sites)
        referenceSeconds <- proc.time()[["elapsed"]] - started
        # Optional installed-package comparison of maximum scaling only.
        # tidyCovariateData's floor(minFraction*N) rule is not D's >= fraction.
        featureExtraction <- list(executed = FALSE)
        if (requireNamespace("FeatureExtraction", quietly = TRUE)) {
            comparisons <- list()
            for (fold in c(1L, 2L, 0L)) {
                long <- do.call(rbind, lapply(seq_along(fixture$sites), function(i) {
                    name <- names(fixture$sites)[i]
                    records <- fixture$sites[[name]]$covariates
                    selected <- names(pooled$folds[[name]])[fold == 0L | pooled$folds[[name]] != fold]
                    records <- records[as.character(records$rowId) %in% selected & records$covariateValue > 0, ]
                    # Explicit synthetic site/local row mapping for this pooled evaluator.
                    records$rowId <- match(as.character(records$rowId), names(pooled$folds[[name]])) + (i - 1L) * 1000
                    records
                }))
                data <- FeatureExtraction::createEmptyCovariateData(cohortIds = 1, aggregated = FALSE, temporal = FALSE)
                data$covariates <- long
                data$covariateRef <- fixture$sites[[1L]]$covariateRef
                data$analysisRef <- fixture$sites[[1L]]$analysisRef
                attr(data, "metaData") <- list(populationSize = pooled$preprocessing[[as.character(fold)]]$n, cohortIds = 1)
                tidy <- FeatureExtraction::tidyCovariateData(data, minFraction = 0, normalize = TRUE, removeRedundancy = FALSE)
                factors <- attr(tidy, "metaData")$normFactors
                expected <- pooled$preprocessing[[as.character(fold)]]$maximum[as.character(factors$covariateId)]
                difference <- abs(factors$maxValue - expected)
                normalized <- dplyr::collect(tidy$covariates)
                keys <- paste(long$rowId, long$covariateId)
                index <- match(paste(normalized$rowId, normalized$covariateId), keys)
                transformed <- long$covariateValue[index] /
                    pooled$preprocessing[[as.character(fold)]]$maximum[as.character(normalized$covariateId)]
                scaleDifference <- abs(normalized$covariateValue - transformed)
                stopifnot(all(difference <= 1e-12 + 1e-12 * abs(expected)),
                    all(scaleDifference <= 1e-12 + 1e-12 * abs(transformed)))
                comparisons[[as.character(fold)]] <- c(maximum = max(difference), transformed = max(scaleDifference))
                Andromeda::close(tidy)
                Andromeda::close(data)
            }
            featureExtraction <- list(executed = TRUE, version = as.character(utils::packageVersion("FeatureExtraction")),
                path = find.package("FeatureExtraction"), errors = comparisons,
                arguments = list(minFraction = 0, normalize = TRUE, removeRedundancy = FALSE))
        }
        saveRDS(list(fixture = fixture, settings = settings, pooled = pooled, local = local,
            featureExtraction = featureExtraction, seconds = referenceSeconds), file.path(work, "d-reference.rds"))
        print(list(referenceSeconds = referenceSeconds, pooledScores = pooled$scores,
            selectedVariance = pooled$selectedVariance, localVariance = vapply(local, function(x) x$selectedVariance, 0.0),
            cyclopsPath = pooled$cyclopsPath, featureExtraction = featureExtraction))
    } else {
        baseline <- readRDS(file.path(work, "d-reference.rds"))
        stopifnot(identical(fixture, baseline$fixture), identical(settings, baseline$settings),
            "initializeCyclopsCoordinateDescent" %in% getNamespaceExports("Cyclops"))
        inputs <- definitions$dInputs(fixture)
        for (name in names(inputs)) {
            inputs[[name]]$evaluation <- list(type = "D",
                folds = lapply(baseline$pooled$transformed, function(x) x[[name]]),
                models = baseline$pooled$models,
                populations = list(local = baseline$local[[name]]$populations[[name]],
                    pooled = baseline$pooled$populations[[name]]),
                matching = definitions$dBase$b1Settings$matching, balance = definitions$dBase$b1Settings$balance)
            saveRDS(inputs[[name]], file.path(work, paste0(name, ".rds")))
        }
        cat("D_SETUP_IDENTICAL_INPUT_AND_SETTINGS\n")
    }
}

if (stage == "dMatching") {
    # Only synthetic evaluation; the historical remote PS/members were not saved.
    started <- proc.time()[["elapsed"]]
    Sys.setenv(FEDERATEDPS_SETUP_ONLY = "true")
    setwd(sourcePath)
    definitions <- new.env()
    sys.source(file.path(sourcePath, "tests/testthat/test-preprocessing-cv.R"), definitions)
    baseline <- readRDS(file.path(work, "d-reference.rds"))
    remote <- readRDS(file.path(work, "d-remote.rds"))
    fixture <- definitions$dFixture()
    stopifnot(identical(fixture, baseline$fixture), identical(definitions$dSettings, baseline$settings),
        identical(lapply(fixture$sites, definitions$dFolds), baseline$pooled$folds))
    matching <- do.call(CohortMethod::createMatchOnPsArgs, definitions$dBase$b1Settings$matching)
    balanceArgs <- do.call(CohortMethod::createComputeCovariateBalanceArgs, definitions$dBase$b1Settings$balance)
    pooledInput <- preparePsData(fixture$sites, fixture$covariateIds,
        stats::setNames(rep(1, length(fixture$covariateIds)), as.character(fixture$covariateIds)))
    raw <- lapply(definitions$dInputs(fixture), preparePsCvDS, folds = 2L, seed = baseline$settings$seed)
    results <- list()
    add <- function(site, comparison, values) {
        results[[length(results) + 1L]] <<- data.frame(site = site, comparison = comparison,
            metric = names(values), value = unname(values))
    }
    # Both existing input constructors retain original, unscaled covariates.
    evaluate <- function(population, site, data) {
        original <- fixture$sites[[site]]$population
        stopifnot(all(vapply(names(original), function(column) identical(population[[column]], original[[column]]), TRUE)),
            identical(rownames(population), rownames(original)),
            identical(attr(population, "metaData"), attr(original, "metaData")))
        population <- population[order(population$rowId), ]
        set.seed(baseline$settings$seed)
        before <- .Random.seed
        matched <- CohortMethod::matchOnPs(population, matching)
        rngUnchanged <- identical(before, .Random.seed)
        stopifnot(all(table(matched$stratumId, matched$treatment) == 1L))
        set.seed(baseline$settings$seed)
        balance <- CohortMethod::computeCovariateBalance(matched, data, balanceArgs)
        balance <- balance[order(balance$covariateId), ]
        list(population = population, matched = matched, balance = balance, rngUnchanged = rngUnchanged,
            pairs = sort(unname(vapply(split(matched, matched$stratumId), function(pair)
                paste(pair$rowId[order(pair$treatment)], collapse = ":"), ""))))
    }
    compare <- function(site, label, a, b, requireEqual = FALSE) {
        stopifnot(identical(a$population$rowId, b$population$rowId),
            identical(a$population$treatment, b$population$treatment),
            identical(a$balance$covariateId, b$balance$covariateId))
        fields <- grep("(MeanTarget|MeanComparator|SdTarget|SdComparator|StdDiff)$", names(a$balance), value = TRUE)
        x <- as.matrix(a$balance[fields]); y <- as.matrix(b$balance[fields])
        missingEqual <- identical(is.na(x), is.na(y))
        error <- max(c(0, abs(x - y)), na.rm = TRUE)
        membership <- vapply(0:1, function(group) {
            aa <- a$matched$rowId[a$matched$treatment == group]
            bb <- b$matched$rowId[b$matched$treatment == group]
            length(setdiff(aa, bb)) + length(setdiff(bb, aa))
        }, 0L)
        if (requireEqual) stopifnot(identical(a$population, b$population),
            identical(a$pairs, b$pairs), all(membership == 0L), missingEqual, error == 0)
        add(site, label, c(psMaxError = max(abs(a$population$propensityScore - b$population$propensityScore)),
            pairsEqual = identical(a$pairs, b$pairs), comparatorMembershipDifference = membership[1L],
            targetMembershipDifference = membership[2L], balanceMaxError = error,
            undefinedMaskEqual = missingEqual, rngUnchanged = a$rngUnchanged && b$rngUnchanged))
        for (side in c("a", "b")) {
            value <- if (side == "a") a else b
            add(site, paste(label, side, sep = ":"), c(targetMatched = sum(value$matched$treatment == 1),
                comparatorMatched = sum(value$matched$treatment == 0),
                maxAbsSmd = max(abs(value$balance$afterMatchingStdDiff), na.rm = TRUE),
                undefinedSmd = sum(is.na(value$balance$afterMatchingStdDiff))))
        }
    }
    controls <- list()
    for (site in names(raw)) {
        original <- fixture$sites[[site]]
        stopifnot(isTRUE(all.equal(as.data.frame(dplyr::collect(raw[[site]]$raw$cohortMethodData$covariates)), original$covariates, tolerance = 0)),
            isTRUE(all.equal(as.data.frame(dplyr::collect(pooledInput$sites[[site]]$cohortMethodData$covariates)), original$covariates, tolerance = 0)))
        ps <- baseline$pooled$populations[[site]]
        joined <- original$population
        joined$propensityScore <- ps$propensityScore[match(joined$rowId, ps$rowId)]
        a <- evaluate(ps, site, pooledInput$sites[[site]]$cohortMethodData)
        b <- evaluate(joined, site, raw[[site]]$raw$cohortMethodData)
        compare(site, "identical_L_PS", a, b, requireEqual = TRUE)
        controls[[site]] <- a
    }
    # One final simulation replay uses the existing fit loop; no CV or remote
    # fit is repeated. It is not a recovered historical worker prediction.
    spec <- combinePsSummaries(lapply(raw, getPsPreprocessingDS, fold = 0L), baseline$settings$minFraction)
    transformed <- lapply(raw, applyPsPreprocessingDS, fold = 0L,
        covariateIds = spec$covariateIds, scales = spec$scales)
    sites <- lapply(transformed, function(x) x$preparedSite)
    prepared <- list(sites = sites, covariateIds = spec$covariateIds, excludedIds = spec$excludedIds,
        rowMap = getFromNamespace(".psRowMap", "FederatedPs")(sites))
    replay <- fitPs(prepared, "simulation", baseline$pooled$selectedVariance,
        do.call(Cyclops::createControl, raw[[1L]]$settings$control), transformed[[1L]]$settings$startingCoefficients)
    stopifnot(replay$models$global$returnFlag == "SUCCESS", remote$finalFit$model$returnFlag == "SUCCESS")
    add("global", "final_fit_replay", c(coefficientErrorVsArchivedRemote =
        max(abs(replay$models$global$coefficients - remote$finalFit$model$coefficients)),
        iterations = replay$models$global$iterations))
    for (site in names(raw)) {
        a <- controls[[site]]
        ps <- replay$populations[[site]]
        b <- evaluate(ps, site, raw[[site]]$raw$cohortMethodData)
        same <- evaluate(ps, site, pooledInput$sites[[site]]$cohortMethodData)
        compare(site, "identical_replay_PS", same, b, requireEqual = TRUE)
        compare(site, "L_vs_final_fit_replay", a, b)
        archived <- remote$evaluations[[remote$finalFit$runId]][[site]]$evaluation$summary
        add(site, "final_fit_replay", c(maxSmdErrorVsArchivedRemote =
            abs(max(abs(b$balance$afterMatchingStdDiff), na.rm = TRUE) - archived$maxAbsSmdAfter[archived$method == "remote"])))
        pa <- a$population$propensityScore; pb <- b$population$propensityScore
        # Pairwise ordering diagnostics on the small synthetic fixture only.
        oa <- outer(pa, pa, "-"); ob <- outer(pb, pb, "-")
        add(site, "PS_order", c(orderPositionsChanged = sum(order(pa) != order(pb)),
            exactTiesBroken = sum(upper.tri(oa) & oa == 0 & ob != 0),
            strictPairOrderReversed = sum(upper.tri(oa) & oa * ob < 0)))
        for (group in 0:1) {
            rows <- which(a$population$treatment == group)
            opposite <- which(a$population$treatment != group)
            changed <- setdiff(union(a$matched$rowId, b$matched$rowId), intersect(a$matched$rowId, b$matched$rowId))
            selected <- rows[a$population$rowId[rows] %in% changed]
            distance <- abs(outer(qlogis(pa[rows]), qlogis(pa[opposite]), "-"))
            near <- vapply(seq_along(rows), function(i) {
                d <- sort(distance[i, ])
                length(d) > 1L && d[2L] - d[1L] <= 1e-12
            }, TRUE)
            add(site, "PS_order", stats::setNames(sum(near[match(selected, rows)]),
                paste0("changedGroup", group, "WithNearEqualNearestDistances")))
        }
        fixed <- a$matched
        fixed$propensityScore <- pb[match(fixed$rowId, b$population$rowId)]
        fixedBalance <- CohortMethod::computeCovariateBalance(fixed, raw[[site]]$raw$cohortMethodData, balanceArgs)
        fixedBalance <- fixedBalance[order(fixedBalance$covariateId), ]
        stopifnot(identical(a$balance, fixedBalance))
        add(site, "fixed_membership_and_weights", c(balanceMaxError = 0))
    }
    for (site in names(raw)) {
        Andromeda::close(raw[[site]]$raw$cohortMethodData)
        Andromeda::close(pooledInput$sites[[site]]$cohortMethodData)
    }
    elapsed <- proc.time()[["elapsed"]] - started
    stopifnot(elapsed <= 600)
    add("global", "diagnostic", c(seconds = elapsed))
    utils::write.csv(do.call(rbind, results), file.path(work, "matching-diagnostic.csv"), row.names = FALSE)
    cat("E1_MATCHING_DIAGNOSTIC_OK", elapsed, "seconds; one final simulation replay, zero CV/remote fits\n")
    print(do.call(rbind, results), row.names = FALSE, digits = 16)
}

if (stage == "dTrain") {
    runD <- function() {
        on.exit(DSI::datashield.logout(connections), add = TRUE)
        # This coordinator reads no fixture, oracle, X, labels or population.
        DSI::datashield.assign.expr(connections, "input", "loadPsSyntheticDS()", async = FALSE)
        sessionIds <- vapply(connections, function(conn) opalr::opal.session_get(conn@opal)$id, "")
        started <- proc.time()[["elapsed"]]
        result <- fitPsDataShieldCv(connections, "input", "Dcv", folds = 2L,
            priorVariances = c(0.1, 1), minFraction = 0.05, seed = 20260907L, maxFitSeconds = 300)
        result$cvWallSeconds <- proc.time()[["elapsed"]] - started
        result$trainingEndedAt <- format(Sys.time(), "%Y-%m-%dT%H:%M:%OS6Z", tz = "UTC")
        result$sessionIds <- sessionIds
        result$coordinator <- list(host = unname(Sys.info()["nodename"]), pid = Sys.getpid(),
            federatedPs = find.package("FederatedPs"), cyclops = find.package("Cyclops"))
        saveRDS(result, file.path(work, "d-remote.rds"))
        stopifnot(length(result$fits) == 5L, all(vapply(result$fits, function(x)
            x$model$returnFlag == "SUCCESS" && all(x$initializations == 1L), TRUE)))
        cat("D_REMOTE_FITS_SUCCESS", length(result$fits), "fits;", result$cvWallSeconds,
            "seconds; final site evaluation follows\n")
        result$evaluations <- list()
        for (name in names(result$fits)) {
            fit <- result$fits[[name]]
            DSI::datashield.assign.expr(connections, fit$stateSymbol,
                sprintf('evaluatePsSiteDS(%s, %s, "%s", %d)', fit$stateSymbol, fit$inputSymbol,
                    fit$runId, fit$step), async = FALSE)
            result$evaluations[[name]] <- DSI::datashield.aggregate(connections,
                sprintf('getPsSiteEvaluationDS(%s, "%s", %d)', fit$stateSymbol, fit$runId, fit$step), async = FALSE)
        }
        saveRDS(result, file.path(work, "d-remote.rds"))
        print(result$scores)
        print(result$selectedVariance)
        print(lapply(result$fits, function(x) list(run = x$runId, status = x$model$returnFlag,
            sweeps = x$model$iterations, cycles = x$step, initializationSeconds = x$initializationSeconds,
            trainingSeconds = x$trainingSeconds, initializations = x$initializations, processes = x$processes)))
        cat("D_TWO_WORKER_CV_AND_REFIT_SUCCESS", result$cvWallSeconds, "seconds\n")
    }
    runD()
}

if (stage == "dCompare") {
    baseline <- readRDS(file.path(work, "d-reference.rds"))
    remote <- readRDS(file.path(work, "d-remote.rds"))
    stopifnot(identical(remote$selectedVariance, baseline$pooled$selectedVariance))
    preprocessing <- checks <- list()
    for (fold in c(1L, 2L, 0L)) {
        a <- remote$preprocessing[[as.character(fold)]]
        b <- baseline$pooled$preprocessing[[as.character(fold)]]
        # DSI decodes integral counts as integer; the independent sparse
        # colSums oracle uses double. Require exact values and named order.
        stopifnot(a$n == b$n, identical(names(a$nonzero), names(b$nonzero)),
            all(a$nonzero == b$nonzero),
            identical(a$covariateIds, b$covariateIds), identical(a$excludedIds, b$excludedIds))
        cat("D_EXACT_COUNTS", fold, "storage", typeof(a$nonzero), typeof(b$nonzero), "\n")
        for (field in c("maximum", "scales")) {
            difference <- abs(a[[field]] - b[[field]])
            ratio <- difference / (1e-12 + 1e-12 * pmax(abs(a[[field]]), abs(b[[field]])))
            stopifnot(all(ratio <= 1))
            checks[[length(checks) + 1L]] <- data.frame(section = "preprocessing", site = "global",
                method = "federated", fold = fold, priorVariance = NA_real_, metric = field,
                value = NA_real_, maxAbsoluteError = max(difference), maxToleranceRatio = max(ratio))
        }
        for (method in c("pooled", "federated")) {
            spec <- if (method == "pooled") b else a
            ids <- baseline$fixture$covariateIds
            preprocessing[[length(preprocessing) + 1L]] <- data.frame(method = method, fold = fold,
                covariateId = ids, nTrain = spec$n, nonzero = unname(spec$nonzero),
                maximum = unname(spec$maximum), retained = ids %in% spec$covariateIds,
                scale = unname(spec$scales[as.character(ids)]))
        }
    }
    cv <- list(pooled = baseline$pooled$validation, federated = remote$validation,
        local = do.call(rbind, lapply(baseline$local, function(x) x$validation)))
    for (method in names(cv)) {
        cv[[method]]$method <- method
        cv[[method]]$selectedVariance <- if (method == "local")
            vapply(cv[[method]]$site, function(name) baseline$local[[name]]$selectedVariance, 0.0) else remote$selectedVariance
        cv[[method]]$cvScore <- vapply(seq_len(nrow(cv[[method]])), function(i) {
            rows <- cv[[method]]$priorVariance == cv[[method]]$priorVariance[i]
            if (method == "local") rows <- rows & cv[[method]]$site == cv[[method]]$site[i]
            sum(cv[[method]]$loss[rows]) / sum(cv[[method]]$n[rows])
        }, 0.0)
    }
    stopifnot(identical(cv$pooled[c("site", "fold", "priorVariance", "n")],
        cv$federated[c("site", "fold", "priorVariance", "n")]))
    for (field in c("loss", "cvScore")) {
        a <- cv$federated[[field]]; b <- cv$pooled[[field]]
        difference <- abs(a - b)
        ratio <- difference / (1e-7 + 1e-7 * pmax(abs(a), abs(b)))
        stopifnot(all(ratio <= 1))
        checks[[length(checks) + 1L]] <- data.frame(section = "CV", site = "global", method = "federated",
            fold = NA_integer_, priorVariance = NA_real_, metric = field, value = NA_real_,
            maxAbsoluteError = max(difference), maxToleranceRatio = max(ratio))
    }
    for (name in names(remote$fits)) {
        fit <- remote$fits[[name]]
        fold <- as.integer(sub(".*f([0-9]+)v[0-9]+$", "\\1", name))
        variance <- c(0.1, 1)[as.integer(sub(".*v([0-9]+)$", "\\1", name))]
        expected <- baseline$pooled$models[[paste(fold, variance, sep = ":")]]
        difference <- abs(fit$model$objective - expected$objective)
        ratio <- difference / (1e-7 + 1e-7 * max(abs(fit$model$objective), abs(expected$objective)))
        stopifnot(ratio <= 1)
        checks[[length(checks) + 1L]] <- data.frame(section = "fit", site = "global", method = "federated",
            fold = fold, priorVariance = variance, metric = "objective", value = fit$model$objective,
            maxAbsoluteError = difference, maxToleranceRatio = ratio)
        for (metric in c("initializationSeconds", "trainingSeconds", "step")) {
            checks[[length(checks) + 1L]] <- data.frame(section = "timing", site = "global", method = "federated",
                fold = fold, priorVariance = variance, metric = metric, value = fit[[metric]],
                maxAbsoluteError = NA_real_, maxToleranceRatio = NA_real_)
        }
        for (site in names(remote$evaluations[[name]])) {
            errors <- remote$evaluations[[name]][[site]]$evaluation$errors
            stopifnot(all(errors["toleranceRatio", ] <= 1))
            for (metric in colnames(errors)) checks[[length(checks) + 1L]] <- data.frame(section = "worker",
                site = site, method = "federated", fold = fold, priorVariance = variance, metric = metric,
                value = NA_real_, maxAbsoluteError = errors["absolute", metric], maxToleranceRatio = errors["toleranceRatio", metric])
        }
    }
    final <- remote$evaluations[[remote$finalFit$runId]]
    matching <- do.call(rbind, lapply(final, function(x) x$evaluation$summary))
    matching$method[matching$method == "remote"] <- "federated"
    for (i in seq_len(nrow(matching))) for (metric in setdiff(names(matching), c("site", "method"))) {
        checks[[length(checks) + 1L]] <- data.frame(section = "matching", site = matching$site[i],
            method = matching$method[i], fold = 0L, priorVariance = if (matching$method[i] == "local")
                baseline$local[[matching$site[i]]]$selectedVariance else remote$selectedVariance,
            metric = metric, value = matching[[metric]][i], maxAbsoluteError = NA_real_, maxToleranceRatio = NA_real_)
    }
    utils::write.csv(do.call(rbind, preprocessing), file.path(work, "preprocessing-summary.csv"), row.names = FALSE)
    utils::write.csv(do.call(rbind, cv), file.path(work, "cv-summary.csv"), row.names = FALSE)
    utils::write.csv(do.call(rbind, checks), file.path(work, "comparison-summary.csv"), row.names = FALSE)
    print(remote$scores)
    print(matching, row.names = FALSE, digits = 8)
    print(do.call(rbind, checks)[vapply(checks, function(x) x$section %in% c("preprocessing", "CV", "fit"), TRUE), ])
    cat("D_TRAINING_ONLY_PREPROCESSING_CV_REFIT_COMPARISON_SUCCESS\n")
}
