# Invented, reduced OMOP-shaped fixtures for package smoke tests only. These
# functions never load connection settings, resolve a host, or call a DB driver.
.syntheticYuhsCdm <- function() {
    old <- if (exists(".Random.seed", .GlobalEnv, inherits = FALSE)) get(".Random.seed", .GlobalEnv) else NULL
    on.exit(if (is.null(old)) {
        if (exists(".Random.seed", .GlobalEnv, inherits = FALSE)) rm(".Random.seed", envir = .GlobalEnv)
    } else assign(".Random.seed", old, .GlobalEnv))
    set.seed(20261025L)
    site <- rep(1:3, each = 120L)
    id <- site * 100000L + rep(seq_len(120L), 3L)
    n <- length(id)
    index <- as.Date("2025-06-01") + rep(0:29, length.out = n)
    features <- matrix(rbinom(n * 8L, 1, 0.35), nrow = n)
    treatment <- rbinom(n, 1, plogis(-0.3 + 0.8 * features[, 1] - 0.6 * features[, 2]))
    for (s in 1:3) treatment[which(site == s)[1:2]] <- 0:1
    person <- data.frame(person_id = id, gender_concept_id = sample(c(8507L, 8532L), n, TRUE),
                         year_of_birth = sample(1950:1995, n, TRUE))
    visits <- rbind(data.frame(visit_occurrence_id = id * 10 + 1L, person_id = id, care_site_id = site,
                             visit_start_date = index, visit_end_date = index + 1L),
                    data.frame(visit_occurrence_id = id * 10 + 2L, person_id = id, care_site_id = site,
                             visit_start_date = index - 30L, visit_end_date = index - 30L))
    # One fabricated person visits both sites 1 and 2: excluded everywhere.
    person <- rbind(person, data.frame(person_id = 999001L, gender_concept_id = 8507L, year_of_birth = 1970L))
    visits <- rbind(visits, data.frame(visit_occurrence_id = 9990011:9990012, person_id = 999001L,
                                    care_site_id = 1:2, visit_start_date = as.Date("2025-06-01"),
                                    visit_end_date = as.Date("2025-06-02")))
    cdm <- list(CARE_SITE = data.frame(care_site_id = 1:3,
        care_site_name = c("Synthetic Severance", "Synthetic Gangnam", "Synthetic Yongin"),
        care_site_source_value = c("10", "20", "30")), PERSON = person,
        VISIT_OCCURRENCE = visits,
        OBSERVATION_PERIOD = data.frame(observation_period_id = seq_len(nrow(person)),
            person_id = person$person_id, observation_period_start_date = as.Date("2023-01-01"),
            observation_period_end_date = as.Date("2026-01-01")))
    cdm$DRUG_EXPOSURE <- data.frame(person_id = c(id, 999001L),
        drug_concept_id = c(ifelse(treatment == 1, 948078L, 923645L), 948078L),
        drug_exposure_start_date = c(index, as.Date("2025-06-01")),
        drug_exposure_end_date = c(index + 29L, as.Date("2025-06-30")),
        visit_occurrence_id = c(id * 10 + 1L, 9990011L))
    domains <- list(c("CONDITION_OCCURRENCE", "condition_concept_id", "condition_start_date"),
                    c("DRUG_EXPOSURE", "drug_concept_id", "drug_exposure_start_date"),
                    c("PROCEDURE_OCCURRENCE", "procedure_concept_id", "procedure_date"),
                    c("MEASUREMENT", "measurement_concept_id", "measurement_date"))
    for (d in seq_along(domains)) {
        info <- domains[[d]]
        records <- do.call(rbind, lapply(1:2, function(j) {
            take <- features[, (d - 1L) * 2L + j] == 1L
            frame <- data.frame(person_id = id[take], concept = 2000000000 + d * 10L + j,
                                date = index[take] - 30L, visit_occurrence_id = id[take] * 10L + 2L)
            names(frame)[2:3] <- info[2:3]
            frame
        }))
        # Invalid links and an old event are deliberately present in every domain.
        bad <- records[rep(1L, 4L), ]
        bad$visit_occurrence_id[1:3] <- c(NA, 888888888, visits$visit_occurrence_id[2])
        bad[[info[3]]][4] <- bad[[info[3]]][4] - 200L
        records <- rbind(records, records[1, ], bad) # repeated record stays binary
        if (d == 2L) {
            records$drug_exposure_end_date <- records$drug_exposure_start_date
            cdm[[info[1]]] <- rbind(cdm[[info[1]]], records[names(cdm[[info[1]]])])
        } else cdm[[info[1]]] <- records
    }
    concepts <- c(8507, 8532, 948078, 923645, unlist(lapply(1:4, function(i) 2000000000 + i * 10 + 1:2)))
    cdm$CONCEPT <- data.frame(concept_id = concepts,
        concept_name = c("Male", "Female", "pantoprazole", "omeprazole", paste("Invented test feature", 1:8)))
    cdm$CONCEPT_ANCESTOR <- data.frame(ancestor_concept_id = c(948078, 923645),
                                     descendant_concept_id = c(948078, 923645))
    cdm
}

.readSyntheticYuhsCdm <- function(directory) {
    tables <- c("CARE_SITE", "PERSON", "VISIT_OCCURRENCE", "OBSERVATION_PERIOD", "DRUG_EXPOSURE",
                "CONDITION_OCCURRENCE", "PROCEDURE_OCCURRENCE", "MEASUREMENT", "CONCEPT", "CONCEPT_ANCESTOR")
    result <- lapply(tables, function(table) {
        path <- file.path(directory, paste0(table, ".csv"))
        if (!file.exists(path)) stop("Missing bundled synthetic CDM table: ", table, "; reinstall FederatedPs")
        x <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = c("", "NA"))
        if (table == "CARE_SITE") x$care_site_source_value <- as.character(x$care_site_source_value)
        for (column in grep("_date$", names(x), value = TRUE)) x[[column]] <- as.Date(x[[column]])
        x
    })
    stats::setNames(result, tables)
}

.prepareSyntheticYuhsTables <- function(cdm, careSiteId) {
    careSiteId <- .validateCareSiteId(careSiteId)
    settings <- getStudySettings("ppi", "default")
    institution <- cdm$CARE_SITE[cdm$CARE_SITE$care_site_id == careSiteId, ]
    if (nrow(institution) != 1L) stop("Synthetic sample has CARE_SITE_ID 1, 2 and 3 only")
    visits <- cdm$VISIT_OCCURRENCE
    attributed <- visits[!is.na(visits$care_site_id) & visits$care_site_id > 0, ]
    membership <- split(attributed$care_site_id, attributed$person_id)
    multisite <- names(membership)[vapply(membership, function(x) length(unique(x)) > 1L, TRUE)]
    visits <- attributed[attributed$care_site_id == careSiteId & !attributed$person_id %in% multisite, ]
    persons <- cdm$PERSON[cdm$PERSON$person_id %in% visits$person_id, ]
    link <- function(x) {
        v <- match(x$visit_occurrence_id, visits$visit_occurrence_id)
        !is.na(v) & !is.na(x$person_id) & x$person_id == visits$person_id[v]
    }
    domains <- list(c("CONDITION_OCCURRENCE", "condition_concept_id", "condition_start_date", "101"),
                    c("DRUG_EXPOSURE", "drug_concept_id", "drug_exposure_start_date", "201"),
                    c("PROCEDURE_OCCURRENCE", "procedure_concept_id", "procedure_date", "301"),
                    c("MEASUREMENT", "measurement_concept_id", "measurement_date", "401"))
    linkage <- do.call(rbind, lapply(domains, function(d) {
        x <- cdm[[d[1]]]; x <- x[x$person_id %in% persons$person_id, ]
        data.frame(table = d[1], candidateRecords = nrow(x), excludedRecords = sum(!link(x)))
    }))
    drug <- cdm$DRUG_EXPOSURE
    drug <- drug[link(drug) & drug$drug_concept_id %in% c(settings$targetIngredients, settings$comparatorIngredients), ]
    drug <- drug[order(drug$drug_exposure_start_date, drug$person_id, drug$drug_concept_id), ]
    drug <- drug[!duplicated(drug$person_id), ]
    drug <- drug[order(drug$person_id), ]
    op <- cdm$OBSERVATION_PERIOD
    op <- op[match(drug$person_id, op$person_id), ]
    p <- persons[match(drug$person_id, persons$person_id), ]
    index <- drug$drug_exposure_start_date
    eligible <- !is.na(op$person_id) & as.integer(format(index, "%Y")) - p$year_of_birth >= settings$minAge &
        index >= op$observation_period_start_date & index <= op$observation_period_end_date
    drug <- drug[which(eligible), ]; op <- op[which(eligible), ]; p <- p[which(eligible), ]
    index <- drug$drug_exposure_start_date
    cohorts <- data.frame(rowId = seq_len(nrow(drug)), personId = drug$person_id,
        personSeqId = seq_len(nrow(drug)), treatment = as.numeric(drug$drug_concept_id %in% settings$targetIngredients),
        cohortStartDate = index, daysToCohortEnd = as.numeric(drug$drug_exposure_end_date - index),
        daysFromObsStart = as.numeric(index - op$observation_period_start_date),
        daysToObsEnd = as.numeric(op$observation_period_end_date - index))
    if (!setequal(cohorts$treatment, 0:1)) stop("Synthetic sample needs both treatment arms")
    covariates <- rbind(data.frame(rowId = cohorts$rowId, covariateId = p$gender_concept_id * 1000 + 1, covariateValue = 1),
        data.frame(rowId = cohorts$rowId, covariateId = floor((as.numeric(format(index, "%Y")) - p$year_of_birth) / 5) * 1000 + 2,
                   covariateValue = 1))
    excluded <- c(settings$targetIngredients, settings$comparatorIngredients)
    excluded <- unique(c(excluded, cdm$CONCEPT_ANCESTOR$descendant_concept_id[
        cdm$CONCEPT_ANCESTOR$ancestor_concept_id %in% excluded]))
    for (d in domains) {
        x <- cdm[[d[1]]]
        row <- match(x$person_id, cohorts$personId)
        keep <- link(x) & !is.na(row) & x[[d[2]]] > 0 & !x[[d[2]]] %in% excluded &
            x[[d[3]]] >= index[row] + settings$longTermStartDays & x[[d[3]]] < index[row]
        take <- which(keep)
        covariates <- rbind(covariates, data.frame(rowId = row[take],
            covariateId = x[[d[2]]][take] * 1000 + as.numeric(d[4]), covariateValue = rep(1, length(take))))
    }
    covariates <- unique(covariates)
    rownames(covariates) <- NULL
    ids <- sort(unique(covariates$covariateId))
    ref <- data.frame(covariateId = ids, analysisId = ids %% 1000, conceptId = floor(ids / 1000))
    ref$covariateName <- cdm$CONCEPT$concept_name[match(ref$conceptId, cdm$CONCEPT$concept_id)]
    age <- ref$analysisId == 2
    ref$covariateName[age] <- paste("Age group", ref$conceptId[age] * 5)
    ref$conceptId[age] <- 0
    settings$definitionVersion <- 2L
    settings$exposureSource <- "synthetic visit-linked drug_exposure"
    settings$featureDefinition <- "synthetic-yuhs-binary-v1"
    settings$partitionPolicy <- "exclude persons visiting multiple positive care_site_ids"
    settings$synthetic <- TRUE # Never negotiates the same contract as real CDM data.
    counts <- c(sum(cohorts$treatment == 1), sum(cohorts$treatment == 0))
    list(cohorts = cohorts, covariates = covariates, covariateRef = ref, analysisRef = .careSiteAnalysis(settings),
        outcomes = data.frame(rowId = numeric(), outcomeId = numeric(), daysToEvent = numeric()),
        metaData = list(targetId = 1, comparatorId = 2, synthetic = TRUE, studyDefinition = settings,
            careSite = stats::setNames(institution, c("careSiteId", "careSiteName", "careSiteSourceValue")),
            sitePartition = data.frame(exclusivePersons = nrow(persons), linkedVisits = nrow(visits),
                multisitePersonsAllCdm = length(multisite),
                unattributedVisitsAllCdm = sum(is.na(cdm$VISIT_OCCURRENCE$care_site_id) | cdm$VISIT_OCCURRENCE$care_site_id <= 0)),
            recordLinkage = linkage, attrition = data.frame(description = "Synthetic PPI default sample",
                targetPersons = counts[1], comparatorPersons = counts[2], targetExposures = counts[1], comparatorExposures = counts[2])))
}

#' Load a database-free three-institution YUHS-shaped sample
#'
#' @param careSiteId One of 1 (Severance), 2 (Gangnam), 3 (Yongin).
#' @param study,scenario Only `ppi` / `default` is supported by this small fixture.
#' @return A local `CohortMethodData` for [fitPs()]. Close with `Andromeda::close()`.
#' @details Reads bundled invented CSV tables, partitions by visit/care site and
#'   prepares binary covariates in R. No connection settings or DB are accessed.
#'   Tests the package pipeline, not SQL Server, HIWARE, full OMOP validation or
#'   clinical validity. Feature metadata explicitly prevents mixing with real data.
#' @export
getSyntheticYuhsStudyData <- function(careSiteId, study = "ppi", scenario = "default") {
    if (!identical(study, "ppi") || !identical(scenario, "default"))
        stop("Synthetic YUHS smoke test supports only Study=ppi / Scenario=default")
    tables <- .prepareSyntheticYuhsTables(.readSyntheticYuhsCdm(
        system.file("extdata", "yuhs-synthetic", package = "FederatedPs")), careSiteId)
    loadNamespace("CohortMethod")
    data <- Andromeda::andromeda()
    complete <- FALSE
    on.exit(if (!complete) Andromeda::close(data))
    for (table in setdiff(names(tables), "metaData")) data[[table]] <- tables[[table]]
    attr(data, "metaData") <- tables$metaData
    class(data) <- "CohortMethodData"
    attr(class(data), "package") <- "CohortMethod"
    complete <- TRUE
    data
}
