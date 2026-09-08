#' Fit a plaintext federated propensity score model at one hospital
#'
#' @param cohortMethodData Hospital-local [CohortMethod::CohortMethodData].
#' @param population Study population with unique `rowId` and binary `treatment`.
#'   Defaults to the cohorts in `cohortMethodData`.
#' @param covariateIds Common feature IDs in training order. `NULL` uses the
#'   sorted union of feature IDs reported by the hospitals.
#' @param scales Common positive divisors in the same feature order.
#' @param config Hospital configuration from [pda::getCloudConfig()].
#' @param runId New alphanumeric identifier shared with the aggregator.
#' @param priorVariance Fixed Laplace variance. The intercept is unpenalized.
#' @param control [Cyclops::createControl()] settings for Lange CPU CCD.
#' @param startingCoefficients Common initial coefficients, intercept first.
#' @param timeout Seconds to wait for each exchange.
#' @return The input population with `propensityScore` and model coefficients
#'   in its `metaData` attribute. Patient rows and PS remain at this hospital.
#' @details Run `aggregatePs()` and one `fitPs()` call per hospital concurrently.
#'   Inputs must use the same feature definitions and absent-value-as-zero
#'   encoding. Scaling is supplied, not estimated separately at each hospital.
#'   Only globally zero columns are removed. No sampling or cross-validation
#'   is performed. The caller retains ownership of `cohortMethodData` and must
#'   close it with `Andromeda::close()` when finished.
#' @importClassesFrom CohortMethod CohortMethodData
#' @importFrom rlang .data
#' @export
fitPs <- function(cohortMethodData, population = NULL, covariateIds = NULL,
                  scales = rep(1, length(covariateIds)), config, runId,
                  priorVariance = 1,
                  control = Cyclops::createControl(convergenceType = "lange"),
                  startingCoefficients = rep(0, length(covariateIds) + 1L),
                  timeout = 300) {
    if (!"aggregate" %in% names(formals(Cyclops::createControl))) {
        stop("Install the Cyclops fork pinned in DESCRIPTION")
    }
    if (is.null(population)) population <- dplyr::collect(cohortMethodData$cohorts)
    rows <- as.character(population$rowId)
    if (anyNA(rows) || anyDuplicated(rows)) stop("rowId must be unique and non-missing")
    if (!is.numeric(population$treatment) || anyNA(population$treatment) ||
        !setequal(population$treatment, c(0, 1))) {
        stop("Each hospital must contain both binary treatment groups")
    }
    if (!all(grepl("^[A-Za-z0-9]+$", c(runId, config$site_id))) || config$site_id == "total") {
        stop("Use alphanumeric run and hospital identifiers; total is reserved")
    }
    if (paste0(runId, "_0_", config$site_id) %in% pda::pdaList(config)) stop("Use a new runId")
    round <- 0L
    exchange <- function(coordinate, statistics) {
        key <- paste0(runId, "_", round)
        roundConfig <- config
        if (round > 0L) {
            roundConfig$dir <- file.path(config$dir, runId, round)
            dir.create(roundConfig$dir, recursive = TRUE, showWarnings = FALSE)
        }
        .putPs(list(coordinate = coordinate, statistics = statistics),
               paste0(key, "_", config$site_id), roundConfig)
        result <- .getPs(paste0(key, "_total"), roundConfig, timeout)
        round <<- round + 1L
        result
    }
    reference <- dplyr::collect(cohortMethodData$covariateRef)
    if (is.null(covariateIds)) covariateIds <- exchange(-3L, reference$covariateId)
    features <- as.character(covariateIds)
    if (anyNA(features) || anyDuplicated(features)) stop("covariateIds must be unique")
    if (length(scales) != length(features) || any(!is.finite(scales)) || any(scales <= 0)) {
        stop("Provide one positive finite scale per feature")
    }
    if (!is.null(names(scales)) && !identical(names(scales), features)) stop("Scale order differs from feature order")
    if (length(startingCoefficients) != length(features) + 1L) stop("Provide one initial coefficient per coordinate")
    if (!is.null(names(startingCoefficients)) &&
        !identical(names(startingCoefficients), c("(Intercept)", features))) {
        stop("Initial coefficient order differs from feature order")
    }
    covariates <- dplyr::collect(dplyr::filter(cohortMethodData$covariates,
        .data$rowId %in% !!population$rowId, .data$covariateId %in% !!covariateIds))
    if (anyDuplicated(covariates[c("rowId", "covariateId")])) stop("Duplicate rowId/covariateId pair")
    if (any(!is.finite(covariates$covariateValue))) stop("Covariate values must be finite")
    rowOrder <- order(population$rowId)
    columns <- match(as.character(covariates$covariateId), features)
    x <- Matrix::sparseMatrix(i = match(as.character(covariates$rowId), rows[rowOrder]),
        j = columns, x = covariates$covariateValue / scales[columns],
        dims = c(length(rows), length(features)), dimnames = list(rows[rowOrder], features))
    reference <- reference[reference$covariateId %in% covariateIds,
                           c("covariateId", "analysisId", "conceptId")]
    analysis <- dplyr::collect(cohortMethodData$analysisRef)
    reference <- merge(reference, analysis[c("analysisId", "analysisName", "domainId",
                                             "isBinary", "missingMeansZero")], by = "analysisId")

    keep <- exchange(-1L, list(specification = list(features = features,
        scales = unname(scales), priorVariance = priorVariance, control = unclass(control),
        startingCoefficients = unname(startingCoefficients),
        cohorts = attr(cohortMethodData, "metaData")[c("targetId", "comparatorId")]),
        reference = reference,
        present = as.vector(Matrix::colSums(x != 0) > 0)))
    x <- x[, keep, drop = FALSE]
    frame <- data.frame(treatment = population$treatment[rowOrder], row.names = rows[rowOrder])
    cyclopsData <- Cyclops::createCyclopsData(treatment ~ 1, data = frame, sx = x,
                                             modelType = "lr", floatingPoint = 64)
    cyclopsData$coefficientNames <- c("(Intercept)", features[keep])
    prior <- Cyclops::createPrior("laplace", variance = priorVariance,
                                  exclude = "(Intercept)", useCrossValidation = FALSE)
    control$aggregate <- exchange
    fit <- Cyclops::fitCyclopsModel(cyclopsData, prior = prior, control = control,
                                    startingCoefficients = startingCoefficients[c(TRUE, keep)])
    if (fit$return_flag != "SUCCESS") stop("Cyclops did not converge: ", fit$return_flag)
    coefficients <- stats::coef(fit)
    exchange(-2L, list(coefficients = unname(coefficients), iterations = fit$iterations))
    ps <- stats::predict(fit)
    if (!setequal(names(ps), rows) || any(!is.finite(ps)) || any(ps <= 0 | ps >= 1)) stop("Invalid prediction rows or values")
    population$propensityScore <- unname(ps[match(rows, names(ps))])
    attr(population, "metaData")$psModelCoef <- coefficients
    attr(population, "metaData")$psModelPriorVariance <- priorVariance
    attr(population, "metaData")$psError <- "OK"
    population
}
