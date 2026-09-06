#' Prepare fixed synthetic propensity score inputs
#'
#' @param sites Named list of exactly two sites. Each contains data frames
#'   `population`, `covariates`, `covariateRef`, and `analysisRef`.
#'   Population requires unique `rowId`, binary `treatment`, and `personSeqId`.
#'   Covariates requires unique `(rowId, covariateId)` pairs and finite
#'   `covariateValue`. Identifiers are exact integer-valued R numeric vectors.
#' @param covariateIds Explicit common feature IDs in training order.
#' @param scales Positive divisors named in exactly the same feature order.
#'
#' @details
#' This boundary is for synthetic inputs, not CDM extraction. Feature meanings
#' must agree across sites. Only globally zero features are excluded; a feature
#' absent from one site is retained. Scaling is supplied, not estimated.
#'
#' An Andromeda-backed `CohortMethodData` is constructed using the table and class
#' convention in CohortMethod 6.0.3's `simulateCohortMethodData()`. Its outcomes
#' table has zero rows and typed `rowId`, `outcomeId`, and `daysToEvent` columns.
#' Matching/balance use the original unscaled covariates and population, not
#' only selected model coefficients. No clinical outcome is generated.
#'
#' @return A list with prepared `sites`, retained `covariateIds`, `excludedIds`,
#'   `scales`, and an explicit pooled `rowMap`. Each site has its original
#'   population, one sparse `x`, named treatment `y`, and `cohortMethodData`.
#'   The caller must use `Andromeda::close()` on each site's `cohortMethodData`
#'   when finished.
#' @importClassesFrom CohortMethod CohortMethodData
#' @export
preparePsData <- function(sites, covariateIds, scales) {
    if (!is.list(sites) || length(sites) != 2L || is.null(names(sites)) ||
        anyNA(names(sites)) || any(!nzchar(names(sites))) || anyDuplicated(names(sites))) {
        stop("Provide exactly two uniquely named synthetic sites")
    }
    featureKeys <- .psIdKeys(covariateIds, "covariateIds")
    if (!length(featureKeys) || anyDuplicated(featureKeys)) {
        stop("covariateIds must be nonempty and unique")
    }
    if (!is.numeric(scales) || length(scales) != length(featureKeys) ||
        !identical(names(scales), featureKeys) || any(!is.finite(scales)) ||
        any(scales <= 0)) {
        stop("scales must be finite positive divisors named in common feature order")
    }

    present <- rep(FALSE, length(featureKeys))
    commonReference <- NULL
    for (site in sites) {
        required <- list(population = c("rowId", "treatment", "personSeqId"),
            covariates = c("rowId", "covariateId", "covariateValue"),
            covariateRef = c("covariateId", "covariateName", "analysisId"),
            analysisRef = c("analysisId", "analysisName", "domainId", "isBinary", "missingMeansZero"))
        for (table in names(required)) {
            if (!is.data.frame(site[[table]]) ||
                !all(required[[table]] %in% names(site[[table]]))) {
                stop("Missing required data frame or columns: ", table)
            }
        }
        population <- site$population
        rows <- .psIdKeys(population$rowId, "population$rowId")
        .psIdKeys(population$personSeqId, "population$personSeqId")
        if (!length(rows) || anyDuplicated(rows)) stop("rowId must be unique within each site")
        if (!is.numeric(population$treatment) || anyNA(population$treatment) ||
            any(!population$treatment %in% c(0, 1)) ||
            length(unique(population$treatment)) != 2L) {
            stop("Each site must contain both binary treatment groups")
        }
        if (any(c("propensityScore", "stratumId", "iptw") %in% names(population))) {
            stop("Input population must precede PS fitting and adjustment")
        }
        covariates <- site$covariates
        covRows <- .psIdKeys(covariates$rowId, "covariates$rowId")
        covKeys <- .psIdKeys(covariates$covariateId, "covariates$covariateId")
        if (any(!covRows %in% rows)) stop("Covariate rowId is missing from its site population")
        if (any(!covKeys %in% featureKeys)) stop("Covariate ID is outside the common feature specification")
        if (anyDuplicated(covariates[c("rowId", "covariateId")])) {
            stop("Duplicate rowId/covariateId pair")
        }
        if (!is.numeric(covariates$covariateValue) || any(!is.finite(covariates$covariateValue))) {
            stop("covariateValue must be finite numeric")
        }
        refKeys <- .psIdKeys(site$covariateRef$covariateId, "covariateRef$covariateId")
        analysisKeys <- .psIdKeys(site$analysisRef$analysisId, "analysisRef$analysisId")
        refAnalysis <- .psIdKeys(site$covariateRef$analysisId, "covariateRef$analysisId")
        if (anyDuplicated(refKeys) || !setequal(refKeys, featureKeys) ||
            anyDuplicated(analysisKeys) || any(!refAnalysis %in% analysisKeys)) {
            stop("Reference tables must uniquely describe all common features and analyses")
        }
        if (anyNA(site$covariateRef$covariateName) ||
            any(!nzchar(site$covariateRef$covariateName)) ||
            anyNA(site$analysisRef) ||
            any(!site$analysisRef$isBinary %in% c("Y", "N")) ||
            any(site$analysisRef$missingMeansZero != "Y")) {
            stop("Reference metadata must describe features with missing values meaning zero")
        }
        reference <- list(covariateRef = site$covariateRef[match(featureKeys, refKeys), ],
            analysisRef = site$analysisRef[order(analysisKeys), ])
        rownames(reference$covariateRef) <- NULL
        rownames(reference$analysisRef) <- NULL
        if (is.null(commonReference)) commonReference <- reference
        if (!identical(reference, commonReference)) stop("Feature meanings differ across sites")
        present[match(covKeys[covariates$covariateValue != 0], featureKeys)] <- TRUE
    }
    if (!any(present)) stop("No nonzero global feature remains")
    retained <- featureKeys[present]
    result <- vector("list", length(sites))
    names(result) <- names(sites)
    complete <- FALSE
    on.exit(if (!complete) for (site in result) {
        if (!is.null(site$cohortMethodData)) Andromeda::close(site$cohortMethodData)
    }, add = TRUE)
    for (name in names(sites)) {
        site <- sites[[name]]
        population <- site$population
        rowOrder <- order(population$rowId)
        rows <- as.character(population$rowId[rowOrder])
        covariates <- site$covariates
        keep <- as.character(covariates$covariateId) %in% retained
        featureIndex <- match(as.character(covariates$covariateId[keep]), retained)
        values <- covariates$covariateValue[keep] / scales[present][featureIndex]
        if (any(!is.finite(values)) || any(values == 0 & covariates$covariateValue[keep] != 0)) {
            stop("Supplied scaling overflowed or underflowed a nonzero value")
        }
        x <- Matrix::sparseMatrix(i = match(as.character(covariates$rowId[keep]), rows),
            j = featureIndex, x = values, dims = c(length(rows), length(retained)),
            dimnames = list(rows, retained))
        # Keep the original, unscaled long table for OHDSI diagnostics.
        data <- Andromeda::andromeda(cohorts = population, covariates = covariates,
            covariateRef = site$covariateRef, analysisRef = site$analysisRef,
            outcomes = data.frame(rowId = numeric(), outcomeId = numeric(), daysToEvent = integer()))
        attr(data, "metaData") <- list(populationSize = nrow(population),
            outcomeIds = numeric(), synthetic = TRUE)
        # This is the official simulation's class assignment to a real
        # Andromeda object with the required tables, not a labelled data frame.
        class(data) <- "CohortMethodData"
        attr(class(data), "package") <- "CohortMethod"
        result[[name]] <- list(population = population, x = x,
            y = stats::setNames(as.numeric(population$treatment[rowOrder]), rows),
            cohortMethodData = data)
        methods::validObject(data)
        if (!CohortMethod::isCohortMethodData(data)) stop("Invalid CohortMethodData construction")
    }
    rowMap <- .psRowMap(result)
    if (anyDuplicated(rowMap$rowKey)) stop("Pooled row keys are not unique")
    complete <- TRUE
    list(sites = result, covariateIds = covariateIds[present],
         excludedIds = covariateIds[!present], scales = scales[present], rowMap = rowMap)
}

.psIdKeys <- function(x, label) {
    if (!is.numeric(x) || inherits(x, "integer64") || !is.null(dim(x)) ||
        any(!is.finite(x)) || any(abs(x) > 2^53 - 1) || any(x != trunc(x))) {
        stop(label, " must use exact integer-valued R numeric identifiers")
    }
    as.character(x)
}

.psRowMap <- function(sites) {
    rowMap <- do.call(rbind, lapply(names(sites), function(name) {
        rows <- rownames(sites[[name]]$x)
        data.frame(site = name, rowId = sites[[name]]$population$rowId[
            match(rows, as.character(sites[[name]]$population$rowId))],
            rowKey = paste0(nchar(name), ":", name, ":", rows))
    }))
    rownames(rowMap) <- NULL
    rowMap
}
