# Local-only and centralized pooled PS fits. No pda, file exchange or aggregator.
fp_baseline_ids <- function(value) {
    ids <- suppressWarnings(as.numeric(as.character(value)))
    if (anyNA(ids) || any(!is.finite(ids)) || any(ids != floor(ids)) || any(abs(ids) > 2^53 - 1))
        stop("Feature IDs must be exactly representable finite integers")
    as.character(ids)
}

fp_baseline_design <- function(population, covariates, reference, analysis, metadata, site) {
    if (length(site) != 1L || !grepl("^[A-Za-z0-9]+$", site)) stop("Invalid site")
    if (!all(c("rowId", "personId", "treatment") %in% names(population)) || !nrow(population))
        stop("Population needs rowId, personId and treatment")
    rows <- as.character(population$rowId)
    persons <- as.character(population$personId)
    if (anyNA(rows) || any(!nzchar(rows)) || anyDuplicated(rows) ||
        anyNA(persons) || any(!nzchar(persons)) || anyDuplicated(persons))
        stop("Each site must have unique non-missing row and person IDs")
    if (!is.numeric(population$treatment) || anyNA(population$treatment) ||
        !setequal(population$treatment, c(0, 1))) stop("Each site needs both binary treatment groups")
    if (!all(c("rowId", "covariateId", "covariateValue") %in% names(covariates)) ||
        !all(c("covariateId", "analysisId", "conceptId") %in% names(reference)) ||
        !all(c("analysisId", "analysisName", "domainId", "isBinary", "missingMeansZero") %in% names(analysis)))
        stop("Incomplete covariate definitions")
    reference$covariateId <- fp_baseline_ids(reference$covariateId)
    if (anyDuplicated(reference$covariateId) || anyNA(analysis$analysisId) || anyDuplicated(analysis$analysisId))
        stop("Duplicate feature or analysis definition")
    reference <- merge(reference[c("covariateId", "analysisId", "conceptId")],
        analysis[c("analysisId", "analysisName", "domainId", "isBinary", "missingMeansZero")],
        by = "analysisId", all.x = TRUE, sort = FALSE)
    reference[] <- lapply(reference, as.character)
    if (anyNA(reference) || any(reference$missingMeansZero != "Y"))
        stop("Missing feature definitions or absent-value-as-zero contract")
    covariates <- covariates[as.character(covariates$rowId) %in% rows, , drop = FALSE]
    covariates$covariateId <- fp_baseline_ids(covariates$covariateId)
    if (anyDuplicated(covariates[c("rowId", "covariateId")]) ||
        !is.numeric(covariates$covariateValue) || any(!is.finite(covariates$covariateValue)))
        stop("Duplicate or non-finite covariates")
    if (!all(covariates$covariateId %in% reference$covariateId)) stop("Unknown covariate definition")
    features <- as.character(sort(as.numeric(reference$covariateId)))
    order <- order(population$rowId)
    population <- population[order, , drop = FALSE]
    rows <- rows[order]
    keys <- paste(site, rows, sep = ":")
    x <- Matrix::sparseMatrix(i = match(as.character(covariates$rowId), rows),
        j = match(covariates$covariateId, features), x = covariates$covariateValue,
        dims = c(length(rows), length(features)), dimnames = list(keys, features))
    population$site <- site
    list(x = x, population = population, reference = reference, metadata = metadata, site = site)
}

fp_baseline_validate_sites <- function(designs) {
    if (length(designs) < 2L || is.null(names(designs)) || anyDuplicated(names(designs)))
        stop("At least two named site designs are required")
    first <- designs[[1]]$metadata
    fields <- c("targetId", "comparatorId", "studyDefinition")
    if (!all(fields %in% names(first))) stop("Missing study contract")
    for (site in names(designs)) {
        d <- designs[[site]]
        if (!identical(site, d$site) || !identical(first[fields], d$metadata[fields]))
            stop("Sites have different study definitions")
    }
    persons <- unlist(lapply(designs, function(d) as.character(d$population$personId)), use.names = FALSE)
    if (anyDuplicated(persons)) stop("Patient overlap across YUHS institutions")
    refs <- unique(do.call(rbind, lapply(designs, `[[`, "reference")))
    if (anyDuplicated(refs$covariateId)) stop("Conflicting feature definitions across sites")
    invisible(TRUE)
}

fp_baseline_pool <- function(designs) {
    fp_baseline_validate_sites(designs)
    axis <- as.character(sort(unique(as.numeric(unlist(lapply(designs, function(d) colnames(d$x)))))))
    aligned <- lapply(designs, function(d) {
        tri <- Matrix::summary(methods::as(d$x, "TsparseMatrix"))
        Matrix::sparseMatrix(i = tri$i, j = match(colnames(d$x), axis)[tri$j], x = tri$x,
            dims = c(nrow(d$x), length(axis)), dimnames = list(rownames(d$x), axis))
    })
    list(x = do.call(rbind, aligned),
         population = do.call(rbind, lapply(designs, `[[`, "population")),
         metadata = designs[[1]]$metadata[c("targetId", "comparatorId", "studyDefinition")])
}

fp_baseline_predict <- function(x, coefficients) {
    if (!identical(names(coefficients), c("(Intercept)", colnames(x))) || any(!is.finite(coefficients)))
        stop("Coefficient names/order/values do not match the fitted design")
    ps <- stats::plogis(as.numeric(coefficients[1] + x %*% coefficients[-1]))
    if (any(!is.finite(ps)) || any(ps <= 0 | ps >= 1)) stop("Invalid propensity scores")
    ps
}

fp_baseline_fit <- function(design, config) {
    keep <- as.vector(Matrix::colSums(design$x != 0) > 0)
    x <- design$x[, keep, drop = FALSE]
    if (!ncol(x)) stop("No nonzero covariates in this model")
    y <- design$population$treatment
    frame <- data.frame(treatment = y, row.names = rownames(x))
    data <- Cyclops::createCyclopsData(treatment ~ 1, data = frame, sx = x,
        modelType = "lr", floatingPoint = 64)
    data$coefficientNames <- c("(Intercept)", colnames(x))
    # The fork activates proximal block CCD via aggregate. This callback is
    # identity-only: all statistics are already local/pooled in this process.
    observe <- utils::getFromNamespace(".newPsSweepProgress", "FederatedPs")(ncol(x) + 1L, config$blockSize)
    control <- Cyclops::createControl(convergenceType = "lange", seed = 1L, threads = 1L,
        noiseLevel = "silent", maxIterations = config$maxIterations, tolerance = config$tolerance,
        blockSize = config$blockSize, alpha = config$alpha,
        aggregate = function(coordinate, statistics) { observe(coordinate); statistics })
    started <- proc.time()[["elapsed"]]
    fit <- Cyclops::fitCyclopsModel(data,
        prior = Cyclops::createPrior("laplace", variance = config$priorVariance,
            exclude = "(Intercept)", useCrossValidation = FALSE),
        control = control, startingCoefficients = rep(0, ncol(x) + 1L))
    if (!identical(fit$return_flag, "SUCCESS")) stop("Cyclops did not converge: ", fit$return_flag)
    coefficients <- stats::coef(fit)
    result <- design$population
    result$propensityScore <- fp_baseline_predict(x, coefficients)
    attr(result, "metaData")$studyDefinition <- design$metadata$studyDefinition
    list(population = result, coefficients = coefficients, features = colnames(x),
        iterations = fit$iterations, fitSeconds = max(0, proc.time()[["elapsed"]] - started),
        returnFlag = fit$return_flag, priorVariance = config$priorVariance,
        blockSize = config$blockSize, alpha = config$alpha, crossValidation = FALSE,
        predictionType = "in-sample", exchangeRounds = 0L)
}

fp_baseline_save <- function(result, directory, method, label) {
    dir.create(directory, recursive = TRUE, showWarnings = FALSE)
    attr(result$population, "metaData")$psModelCoef <- result$coefficients
    attr(result$population, "metaData")$psModelPriorVariance <- result$priorVariance
    attr(result$population, "metaData")$psError <- "OK"
    attr(result$population, "metaData")$method <- method
    saveRDS(result$population, file.path(directory, "result.rds"))
    saveRDS(result[setdiff(names(result), "population")], file.path(directory, "model.rds"))
    utils::write.csv(data.frame(feature = names(result$coefficients), coefficient = unname(result$coefficients)),
        file.path(directory, "coefficients.csv"), row.names = FALSE)
    data.frame(method = method, site = label, n = nrow(result$population),
        treated = sum(result$population$treatment == 1), comparator = sum(result$population$treatment == 0),
        features = length(result$features), iterations = result$iterations,
        fitSeconds = result$fitSeconds, priorVariance = result$priorVariance,
        blockSize = result$blockSize, alpha = result$alpha, predictionType = "in-sample")
}

fp_baseline_verify <- function(design, directory) {
    population <- readRDS(file.path(directory, "result.rds"))
    model <- readRDS(file.path(directory, "model.rds"))
    for (name in c("site", "rowId", "personId", "treatment"))
        if (!identical(as.character(population[[name]]), as.character(design$population[[name]])))
            stop("Saved result row mapping differs: ", name)
    if (!identical(model$returnFlag, "SUCCESS") || !identical(model$exchangeRounds, 0L))
        stop("Invalid baseline model completion")
    x <- design$x[, model$features, drop = FALSE]
    expected <- fp_baseline_predict(x, model$coefficients)
    if (length(population$propensityScore) != length(expected) ||
        any(!is.finite(population$propensityScore)) || max(abs(expected - population$propensityScore)) > 1e-10)
        stop("Saved PS values do not match coefficients")
    invisible(TRUE)
}

fp_map_federated_result <- function(design, fit, common, config) {
    if (!identical(as.character(fit$rowIds), as.character(design$population$rowId)) ||
        !isTRUE(all.equal(fit$coefficients, common, tolerance = 1e-10)))
        stop("Federated coefficients or patient row mapping differ")
    if (is.null(names(common)) || anyDuplicated(names(common)) ||
        names(common)[1] != "(Intercept)" || any(!is.finite(common))) stop("Invalid federated coefficients")
    localBeta <- common[c("(Intercept)", colnames(design$x))]
    missing <- is.na(localBeta)
    if (any(missing[-1])) {
        absent <- colnames(design$x)[missing[-1]]
        if (any(Matrix::colSums(design$x[, absent, drop = FALSE] != 0) > 0))
            stop("Federated model omitted a nonzero feature")
        localBeta[missing] <- 0
    }
    names(localBeta) <- c("(Intercept)", colnames(design$x))
    expected <- fp_baseline_predict(design$x, localBeta)
    if (length(fit$propensityScore) != length(expected) || any(!is.finite(fit$propensityScore)) ||
        max(abs(fit$propensityScore - expected)) > 1e-8) stop("Federated PS do not match coefficients")
    population <- design$population
    population$propensityScore <- fit$propensityScore
    attr(population, "metaData")$studyDefinition <- design$metadata$studyDefinition
    list(population = population, coefficients = common, features = names(common)[-1],
        iterations = fit$iterations, fitSeconds = fit$fitSeconds, returnFlag = "SUCCESS",
        priorVariance = 1, blockSize = config$blockSize, alpha = config$alpha, crossValidation = FALSE,
        predictionType = "in-sample", exchangeRounds = fit$rounds)
}
