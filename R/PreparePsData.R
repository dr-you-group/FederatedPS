#' Prepare fixed propensity score inputs
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
#' This boundary accepts extracted inputs; it does not query a CDM. Feature meanings
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
        stop("Provide exactly two uniquely named sites")
    }
    .preparePsSites(sites, covariateIds, scales)
}

# A worker uses an agreed exclusion mask; local absence is not global absence.
.preparePsSites <- function(sites, covariateIds, scales, excludedIds = NULL) {
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
        analysis <- site$analysisRef
        completeGender <- is.na(analysis$missingMeansZero) &
            analysis$analysisName == "DemographicsGender" & analysis$isBinary == "Y"
        # FE 3.14 leaves this categorical metadata NULL and omits unknown
        # genders. Accept structural zeroes for the other categories only when
        # EVERY row has exactly one explicit known category. Never fill missing
        # gender, rewrite FE metadata, or relax the synthetic input contract.
        if (any(completeGender) && identical(site$metadata$dataMode, "cdm")) {
            for (id in analysis$analysisId[completeGender]) {
                categoryIds <- site$covariateRef$covariateId[site$covariateRef$analysisId == id]
                categories <- covariates[covariates$covariateId %in% categoryIds, ]
                if (!all(categories$covariateValue == 1) || anyDuplicated(categories$rowId) ||
                    !setequal(categories$rowId, population$rowId)) stop("Incomplete or ambiguous FE gender encoding")
            }
        } else completeGender[] <- FALSE
        binaryHistory <- is.na(analysis$missingMeansZero) & analysis$isBinary == "Y" &
            analysis$analysisName %in% c("ConditionOccurrenceLongTerm", "ConditionOccurrenceShortTerm",
                "DrugExposureLongTerm", "DrugExposureShortTerm", "ProcedureOccurrenceLongTerm", "ProcedureOccurrenceShortTerm")
        if (any(binaryHistory) && identical(site$metadata$dataMode, "cdm") &&
            identical(site$metadata$featureExtractionVersion, "3.14.0")) {
            ref <- site$covariateRef[site$covariateRef$analysisId %in% analysis$analysisId[binaryHistory], ]
            if (!all(c("valueType", "isCollected") %in% names(ref)) ||
                anyNA(ref[c("valueType", "isCollected")]) || !all(ref$valueType == "binary") ||
                !all(ref$isCollected) || any(!covariates$covariateValue[covariates$covariateId %in% ref$covariateId] %in% c(0, 1))) {
                stop("FE history requires explicit collection coverage and binary values")
            }
        } else binaryHistory[] <- FALSE
        # FE's public DomainConcept builder marks binary histories Y while
        # leaving missingMeansZero NULL. The explicitly collected history
        # contract defines absent events as zero; original metadata is retained.
        zeroContract <- !is.na(analysis$missingMeansZero) & analysis$missingMeansZero == "Y"
        if (anyNA(site$covariateRef$covariateName) ||
            any(!nzchar(site$covariateRef$covariateName)) ||
            anyNA(analysis[setdiff(names(analysis), "missingMeansZero")]) ||
            any(!analysis$isBinary %in% c("Y", "N")) || any(!(zeroContract | completeGender | binaryHistory))) {
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
    if (!is.null(excludedIds)) {
        excludedKeys <- .psIdKeys(excludedIds, "excludedIds")
        if (anyDuplicated(excludedKeys) || any(!excludedKeys %in% featureKeys) ||
            any(present[match(excludedKeys, featureKeys)])) {
            stop("Agreed zero-column mask is invalid for this site's input")
        }
        present <- !featureKeys %in% excludedKeys
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
            outcomeIds = numeric(), synthetic = !identical(site$metadata$dataMode, "cdm"))
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

#' Combine training-only site summaries for propensity score preprocessing
#'
#' @param summaries Named site summaries returned by the registered server
#'   function `getPsPreprocessingDS()`. No individual-level inputs are accepted.
#' @param minFraction Retain a nonzero feature when its nonzero count divided
#'   by the total training population is greater than or equal to this value.
#' @details Candidate order, meanings, time windows, value types, collection
#'   coverage and missing-as-zero semantics must agree. This implements only
#'   global zero removal, nonzero-frequency filtering and maximum scaling.
#'   Counts and maxima are research disclosures, not privacy guarantees.
#' @return A plain list with candidate/retained/excluded IDs, training count,
#'   nonzero counts, maxima, retained scales, fold and common metadata.
#' @export
combinePsSummaries <- function(summaries, minFraction = 0) {
    if (!is.list(summaries) || !length(summaries) || is.null(names(summaries)) ||
        anyNA(names(summaries)) || any(!nzchar(names(summaries))) || anyDuplicated(names(summaries))) {
        stop("Provide uniquely named site summaries")
    }
    if (!is.numeric(minFraction) || length(minFraction) != 1L ||
        !is.finite(minFraction) || minFraction < 0 || minFraction > 1) stop("Invalid minFraction")
    expectedNames <- c("site", "covariateIds", "reference", "fold", "folds", "seed", "control",
        "n", "totalN", "validationN", "nonzero", "maximum")
    first <- summaries[[1L]]
    if (!is.list(first) || !identical(names(first), expectedNames)) stop("Only training summary fields are accepted")
    ids <- .psIdKeys(first$covariateIds, "summary covariateIds")
    if (!length(ids) || anyDuplicated(ids)) stop("Invalid summary feature order")
    for (name in names(summaries)) {
        value <- summaries[[name]]
        if (!is.list(value) || !identical(value$site, name) ||
            !identical(names(value), names(first)) ||
            !identical(value$covariateIds, first$covariateIds) ||
            !identical(value$reference, first$reference) ||
            !identical(value$fold, first$fold) || !identical(value$folds, first$folds) ||
            !identical(value$seed, first$seed) || !identical(value$control, first$control)) {
            stop("Site summary identity, feature meanings, fold or settings disagree")
        }
        counts <- c(value$n, value$totalN, value$validationN, value$nonzero)
        if (!is.numeric(counts) || any(!is.finite(counts)) || any(counts != floor(counts)) ||
            length(value$n) != 1L || value$n <= 0 || length(value$totalN) != 1L ||
            length(value$validationN) != 1L || value$validationN < 0 ||
            value$n + value$validationN != value$totalN ||
            !identical(names(value$nonzero), ids) || !identical(names(value$maximum), ids) ||
            any(value$nonzero < 0 | value$nonzero > value$n) ||
            !is.numeric(value$maximum) || any(!is.finite(value$maximum)) || any(value$maximum < 0) ||
            any((value$maximum == 0) != (value$nonzero == 0))) stop("Invalid training summary values")
    }
    n <- sum(vapply(summaries, function(x) x$n, 0.0))
    nonzero <- Reduce(`+`, lapply(summaries, function(x) x$nonzero))
    maximum <- Reduce(pmax, lapply(summaries, function(x) x$maximum))
    keep <- nonzero > 0 & nonzero / n >= minFraction
    if (!any(keep)) stop("No feature remains after training-only preprocessing")
    list(covariateIds = first$covariateIds[keep], excludedIds = first$covariateIds[!keep],
        zeroIds = first$covariateIds[nonzero == 0], scales = maximum[keep], n = n,
        nonzero = nonzero, maximum = maximum, candidateIds = first$covariateIds,
        fold = first$fold, minFraction = minFraction, reference = first$reference)
}

.psTrainingSummary <- function(input, fold) {
    if (!is.list(input) || !isTRUE(input$cvPrepared) || !is.numeric(fold) ||
        length(fold) != 1L || !is.finite(fold) || fold != floor(fold) ||
        fold < 0 || fold > input$folds) stop("Invalid prepared CV input or fold")
    selected <- if (fold == 0) rep(TRUE, length(input$foldId)) else input$foldId != fold
    x <- input$raw$x[selected, , drop = FALSE]
    maximum <- vapply(seq_len(ncol(x)), function(j) {
        from <- x@p[j] + 1L; to <- x@p[j + 1L]
        if (from > to) 0 else max(0, x@x[from:to])
    }, 0.0)
    list(site = input$name, covariateIds = input$covariateIds,
        reference = input$reference, fold = as.integer(fold), folds = input$folds,
        seed = input$seed, control = input$settings$control, n = as.numeric(sum(selected)),
        totalN = as.numeric(nrow(input$raw$x)), validationN = as.numeric(sum(!selected)),
        nonzero = Matrix::colSums(x != 0),
        maximum = stats::setNames(maximum, colnames(x)))
}

.psApplyTrainingSpec <- function(input, fold, covariateIds, scales) {
    summary <- .psTrainingSummary(input, fold)
    keys <- .psIdKeys(covariateIds, "retained covariateIds")
    positions <- match(keys, colnames(input$raw$x))
    if (!length(keys) || anyNA(positions) || anyDuplicated(keys) || is.unsorted(positions) ||
        !is.numeric(scales) || length(scales) != length(keys) || any(!is.finite(scales)) ||
        any(scales <= 0)) stop("Invalid common training mask or scales")
    if (any(scales < summary$maximum[keys])) stop("Common maximum is smaller than a local training maximum")
    selected <- if (fold == 0) rep(TRUE, length(input$foldId)) else input$foldId != fold
    # Raw sparse conversion and OHDSI data are reused. A common mask never
    # removes a column merely because it is absent at this site.
    original <- input$raw$x[, positions, drop = FALSE]
    x <- original %*% Matrix::Diagonal(x = 1 / scales)
    dimnames(x) <- list(rownames(input$raw$x), keys)
    if (any(!is.finite(x@x)) || Matrix::nnzero(x) != Matrix::nnzero(original)) {
        stop("Training scaling overflowed or underflowed")
    }
    result <- input
    result$preparedSite <- input$raw
    result$preparedSite$x <- x[selected, , drop = FALSE]
    result$preparedSite$y <- input$raw$y[selected]
    rows <- rownames(result$preparedSite$x)
    result$preparedSite$population <- input$site$population[
        as.character(input$site$population$rowId) %in% rows, , drop = FALSE]
    result$validation <- list(x = x[!selected, , drop = FALSE], y = input$raw$y[!selected])
    result$trainingFold <- as.integer(fold)
    result$excludedIds <- input$covariateIds[!input$covariateIds %in% covariateIds]
    result$scales <- stats::setNames(as.numeric(scales), keys)
    result$settings$startingCoefficients <- stats::setNames(rep(0, length(keys) + 1L), c("(Intercept)", keys))
    result
}
