#' Fit a federated propensity score model from a prepared design matrix
#'
#' Same wire protocol as [fitPs()], but the hospital supplies its design matrix
#' directly instead of a `CohortMethodData`. Intended for protocol and
#' scalability testing where no CDM connection is available.
#'
#' @param x Sparse design matrix, rows ordered by `rowIds`, columns named by
#'   this hospital's own feature identifiers.
#' @param treatment Binary treatment vector aligned with the rows of `x`.
#' @param rowIds Unique row identifiers aligned with the rows of `x`.
#' @param covariateIds Common feature identifiers. `NULL` negotiates the sorted
#'   union with the other hospitals.
#' @param config,runId,priorVariance,control,startingCoefficients,timeout As [fitPs()].
#' @return A list with the common coefficients, the local propensity scores and
#'   per-round exchange counts.
#' @export
fitPsDesign <- function(x, treatment, rowIds, covariateIds = NULL, config, runId,
                        priorVariance = 1,
                        control = Cyclops::createControl(convergenceType = "lange"),
                        startingCoefficients = NULL, timeout = 300) {
    if (length(dim(x)) != 2L || nrow(x) != length(rowIds) ||
        nrow(x) != length(treatment) || nrow(x) == 0L || ncol(x) == 0L) {
        stop("x, treatment and rowIds must describe the same nonempty rows")
    }
    if (is.null(colnames(x)) || anyNA(colnames(x)) || anyDuplicated(colnames(x))) {
        stop("x must have unique, non-missing feature identifiers")
    }
    if (!"aggregate" %in% names(formals(Cyclops::createControl))) {
        stop("Install the Cyclops fork pinned in DESCRIPTION")
    }
    rows <- as.character(rowIds)
    if (anyNA(rows) || anyDuplicated(rows)) stop("rowId must be unique and non-missing")
    if (!is.numeric(treatment) || anyNA(treatment) || !setequal(treatment, c(0, 1))) {
        stop("Each hospital must contain both binary treatment groups")
    }
    if (!all(grepl("^[A-Za-z0-9]+$", c(runId, config$site_id))) || config$site_id == "total") {
        stop("Use alphanumeric run and hospital identifiers; total is reserved")
    }
    .fpsProgress("model-input", "Preparing local model inputs and negotiating features")
    round <- 0L
    counts <- new.env(); counts$overhead <- 0L; counts$loop <- 0L; counts$conv <- 0L
    counts$bytes <- 0
    exchange <- function(coordinate, statistics) {
        key <- paste0(runId, "_", round)
        roundConfig <- config
        if (round > 0L) {
            roundConfig$dir <- file.path(config$dir, runId, round)
            dir.create(roundConfig$dir, recursive = TRUE, showWarnings = FALSE)
        }
        if (coordinate < 0L) counts$overhead <- counts$overhead + 1L
        else {
            counts$loop <- counts$loop + 1L
            if (coordinate == 0L) counts$conv <- counts$conv + 1L
            counts$bytes <- counts$bytes + length(statistics)
        }
        .putPs(list(coordinate = coordinate, statistics = statistics),
               paste0(key, "_", config$site_id), roundConfig)
        result <- .getPs(paste0(key, "_total"), roundConfig, timeout)
        round <<- round + 1L
        result
    }
    localIds <- colnames(x)
    if (is.null(localIds)) stop("x must have feature identifiers as column names")
    # Send identifiers in their native type so that the aggregator's
    # sort(unique(.)) reproduces fitPs()'s numeric feature ordering. Sending
    # them as strings would sort lexicographically ("1000" before "999") and
    # silently give a different coordinate order, hence different blocks.
    numericIds <- suppressWarnings(as.numeric(localIds))
    if (anyNA(numericIds)) stop("Feature identifiers must be numeric")
    if (is.null(covariateIds)) covariateIds <- exchange(-3L, numericIds)
    features <- as.character(covariateIds)
    if (anyNA(features) || anyDuplicated(features)) stop("covariateIds must be unique")
    if (is.null(startingCoefficients)) startingCoefficients <- rep(0, length(features) + 1L)
    if (length(startingCoefficients) != length(features) + 1L) {
        stop("Provide one initial coefficient per coordinate")
    }
    # Re-express the local matrix in the common feature order.
    j <- match(localIds, features)
    if (anyNA(j)) stop("Local features are not contained in the common feature set")
    tri <- Matrix::summary(methods::as(x, "TsparseMatrix"))
    xx <- Matrix::sparseMatrix(i = tri$i, j = j[tri$j], x = tri$x,
                               dims = c(length(rows), length(features)),
                               dimnames = list(rows, features))
    reference <- data.frame(covariateId = features, analysisId = 1L, conceptId = 0L,
                            analysisName = "design", domainId = "design",
                            isBinary = "Y", missingMeansZero = "Y",
                            stringsAsFactors = FALSE)
    keep <- exchange(-1L, list(specification = list(protocol = .protocolVersion,
        features = features, scales = rep(1, length(features)),
        priorVariance = priorVariance, control = unclass(control),
        startingCoefficients = unname(startingCoefficients),
        cohorts = list(targetId = 0, comparatorId = 0)),
        reference = reference,
        present = as.vector(Matrix::colSums(xx != 0) > 0)))
    xx <- xx[, keep, drop = FALSE]
    frame <- data.frame(treatment = treatment, row.names = rows)
    cyclopsData <- Cyclops::createCyclopsData(treatment ~ 1, data = frame, sx = xx,
                                              modelType = "lr", floatingPoint = 64)
    cyclopsData$coefficientNames <- c("(Intercept)", features[keep])
    prior <- Cyclops::createPrior("laplace", variance = priorVariance,
                                  exclude = "(Intercept)", useCrossValidation = FALSE)
    control$aggregate <- exchange
    .fpsProgress("fitting", "Cyclops fitting; see aggregator for current-sweep progress")
    tFit <- Sys.time()
    fit <- Cyclops::fitCyclopsModel(cyclopsData, prior = prior, control = control,
                                    startingCoefficients = startingCoefficients[c(TRUE, keep)])
    fitSecs <- as.numeric(difftime(Sys.time(), tFit, units = "secs"))
    if (fit$return_flag != "SUCCESS") stop("Cyclops did not converge: ", fit$return_flag)
    coefficients <- stats::coef(fit)
    exchange(-2L, list(coefficients = unname(coefficients), iterations = fit$iterations))
    .fpsProgress("predicting", "Computing local propensity scores")
    ps <- stats::predict(fit)
    list(coefficients = coefficients, propensityScore = unname(ps[match(rows, names(ps))]),
         rowIds = rowIds, iterations = fit$iterations, keep = keep,
         rounds = round, loopRounds = counts$loop, convRounds = counts$conv,
         overheadRounds = counts$overhead, payloadDoubles = counts$bytes,
         fitSeconds = fitSecs)
}
