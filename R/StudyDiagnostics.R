#' Summarize the original binary covariates before PS fitting
#'
#' @param cohortMethodData Data returned by [getDbStudyData()].
#' @return List with counts, covariate-specific prevalences and absolute SMD,
#'   plus domain summaries. No propensity model or matching is performed.
#' @details This helper is for the binary feature settings used by the study
#'   runner. The SMD denominator is sqrt((pT*(1-pT)+pC*(1-pC))/2). A constant
#'   equal feature has SMD zero; unequal constants have infinite SMD. Absence of
#'   a domain is a capture warning, not evidence of clinical absence.
#' @export
describeStudyData <- function(cohortMethodData) {
    cohorts <- dplyr::collect(cohortMethodData$cohorts)
    n <- c(target = sum(cohorts$treatment == 1), comparator = sum(cohorts$treatment == 0))
    if (any(n == 0)) stop("Both arms are needed to describe balance")
    summary <- cohortMethodData$covariates |>
        dplyr::inner_join(dplyr::select(cohortMethodData$cohorts, "rowId", "treatment"), by = "rowId") |>
        dplyr::group_by(.data$covariateId, .data$treatment) |>
        dplyr::summarise(nonzero = dplyr::n(), total = sum(.data$covariateValue),
                         minimum = min(.data$covariateValue), maximum = max(.data$covariateValue), .groups = "drop") |>
        dplyr::collect()
    if (any(summary$minimum != 1 | summary$maximum != 1)) stop("describeStudyData requires binary occurrence covariates")
    ref <- dplyr::collect(cohortMethodData$covariateRef)
    analysis <- dplyr::collect(cohortMethodData$analysisRef)
    result <- merge(ref, analysis, by = "analysisId")
    for (arm in c(0, 1)) {
        values <- summary[summary$treatment == arm, ]
        count <- values$nonzero[match(result$covariateId, values$covariateId)]
        count[is.na(count)] <- 0
        result[[if (arm == 1) "targetCount" else "comparatorCount"]] <- count
    }
    result$targetPrevalence <- result$targetCount / n[1]
    result$comparatorPrevalence <- result$comparatorCount / n[2]
    result$smdDenominator <- sqrt((result$targetPrevalence*(1-result$targetPrevalence) +
                                  result$comparatorPrevalence*(1-result$comparatorPrevalence))/2)
    delta <- abs(result$targetPrevalence-result$comparatorPrevalence)
    result$absoluteSmd <- ifelse(delta == 0, 0, delta/result$smdDenominator)
    result <- result[order(result$covariateId), ]
    domainCounts <- table(result$domainId)
    domains <- data.frame(domainId = unique(c("Demographics", "Condition", "Drug", "Procedure", "Measurement",
        as.character(result$domainId))), stringsAsFactors = FALSE)
    domains$features <- as.integer(domainCounts[match(domains$domainId, names(domainCounts))])
    domains$features[is.na(domains$features)] <- 0L
    domains$captureWarning <- domains$features == 0L
    list(counts = data.frame(targetPersons = n[1], comparatorPersons = n[2],
        features = nrow(result), nonzero = sum(summary$nonzero),
        maxAbsoluteSmd = max(result$absoluteSmd), meanAbsoluteSmd = mean(result$absoluteSmd),
        abovePointOne = sum(result$absoluteSmd > 0.1)), covariates = result, domains = domains)
}
