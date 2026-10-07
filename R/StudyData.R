#' Prepare a named study from a PostgreSQL OMOP CDM
#'
#' @param connectionDetails A [DatabaseConnector::createConnectionDetails()]
#'   object for PostgreSQL, as used by CDM-loader.
#' @param cdmDatabaseSchema Unquoted CDM schema name containing clinical and
#'   vocabulary tables, for example `mimiciv`, `synpuf` or `ehrshot`.
#' @param study Name from [listStudies()].
#' @param scenario Design from [getStudySettings()].
#' @param cohortDatabaseSchema Writable analysis schema for public-study cohorts.
#'   Required for public studies; ignored by legacy presets.
#' @param cohortTable Public-study cohort table prefix.
#' @param generateCohorts Generate public cohorts first; FALSE reuses cohorts
#'   generated with the same definition by [generateStudyCohorts()].
#' @return Hospital-local [CohortMethod::CohortMethodData] for [fitPs()].
#'   Its `metaData` contains `studyDefinition`, resolved ingredients (legacy) or
#'   resolved concept sets/hashes (public), and cohort counts in `attrition`.
#'   No outcomes are extracted.
#'   The caller must close the object with `Andromeda::close()`.
#' @details Uses a dedicated connection and session-local tables/views; source
#'   CDM tables are not changed. CohortMethod's installed cohort SQL retains its
#'   native observation-period join. FeatureExtraction supplies age group, sex
#'   and binary condition, drug, procedure and measurement occurrence features.
#'   Legacy study-specific features end before the linked acute episode.
#'   Public-study features use the registry's pre-index-day windows. Public
#'   cohort tables are generated in the separate supplied analysis schema.
#'
#'   A missing vocabulary definition, overlapping observation periods yielding
#'   duplicate patients, or an empty treatment arm raises an error before
#'   covariate extraction. Counts must be reassessed in each CDM snapshot. These
#'   helpers prepare PS benchmarks, not outcome analyses or clinical trial
#'   replications. Existing callers can continue supplying their own
#'   CohortMethodData directly to [fitPs()].
#' @export
getDbStudyData <- function(connectionDetails, cdmDatabaseSchema, study = "opioid",
                           scenario = c("default", "studySpecific"),
                           cohortDatabaseSchema = NULL, cohortTable = "fps_cohort",
                           generateCohorts = TRUE) {
    settings <- getStudySettings(study, scenario)
    if (length(cdmDatabaseSchema) != 1L || is.na(cdmDatabaseSchema) ||
        !grepl("^[A-Za-z_][A-Za-z0-9_]*$", cdmDatabaseSchema) ||
        grepl("^pg_", cdmDatabaseSchema, ignore.case = TRUE)) {
        stop("Provide an unquoted CDM schema name, for example mimiciv")
    }
    connection <- DatabaseConnector::connect(connectionDetails)
    on.exit(DatabaseConnector::disconnect(connection), add = TRUE)
    if (!identical(DatabaseConnector::dbms(connection), "postgresql")) {
        stop("getDbStudyData supports PostgreSQL CDMs loaded by CDM-loader")
    }
    execute <- function(file, ...) {
        sql <- paste(readLines(system.file("sql", "postgresql", file,
                                          package = "FederatedPs"), warn = FALSE), collapse = "\n")
        sql <- SqlRender::render(sql, cdm_database_schema = cdmDatabaseSchema, ...)
        DatabaseConnector::executeSql(connection, sql, progressBar = FALSE)
    }
    query <- function(sql) DatabaseConnector::querySql(connection, sql, snakeCaseToCamelCase = TRUE)
    specific <- settings$scenario == "studySpecific"
    public <- !is.null(settings$sourceType)
    attrition <- NULL
    if (public) {
        if (is.null(cohortDatabaseSchema)) stop("Public studies require a separate cohortDatabaseSchema")
        .studyIdentifier(cohortDatabaseSchema)
        .studyIdentifier(cohortTable)
        if (identical(cdmDatabaseSchema, cohortDatabaseSchema)) stop("Use a separate analysis schema")
        definitions <- getStudyCohortDefinitions(study, settings$scenario)
        if (generateCohorts) .generateStudyCohorts(connection, cdmDatabaseSchema,
            cohortDatabaseSchema, cohortTable, study, settings$scenario)
        .checkStoredStudyDefinition(connection, cohortDatabaseSchema, cohortTable, definitions)
        resolved <- .resolveStudyConcepts(connection, cdmDatabaseSchema, definitions)
        attrition <- .preparePublicExposure(connection, cdmDatabaseSchema,
            cohortDatabaseSchema, cohortTable, definitions)
        target <- .exposureSeedIds(definitions$json[1])
        comparator <- .exposureSeedIds(definitions$json[2])
    } else {
        ingredients <- list("1" = settings$targetIngredients, "0" = settings$comparatorIngredients)
        atc <- list("1" = settings$targetAtc, "0" = settings$comparatorAtc)
        if (specific) {
            ingredients[["-1"]] <- unique(c(unlist(ingredients), settings$extraWashoutIngredients))
            atc[["-1"]] <- unique(c(unlist(atc), settings$washoutAtc))
        }
        values <- function(groups, quote = FALSE) {
            rows <- unlist(lapply(names(groups), function(arm) {
                ids <- groups[[arm]]
                if (!length(ids)) return(character())
                ids <- if (quote) paste0("'", ids, "'") else format(ids, scientific = FALSE, trim = TRUE)
                paste0("(", arm, ", ", ids, ")")
            }), use.names = FALSE)
            if (!length(rows)) return(if (quote) "(1, '')" else "(1, 0)")
            paste(rows, collapse = ", ")
        }
        execute("StudyConcepts.sql", ingredient_rows = values(ingredients), atc_rows = values(atc, TRUE))
        missingIngredients <- query(paste0(
            "SELECT DISTINCT r.ingredient_id FROM fps_requested_ingredients r WHERE NOT EXISTS (",
            "SELECT 1 FROM ", cdmDatabaseSchema, ".concept c WHERE c.concept_id = r.ingredient_id ",
            "AND c.concept_class_id = 'Ingredient' AND c.vocabulary_id IN ('RxNorm', 'RxNorm Extension'))"))
        missingAtc <- query("SELECT DISTINCT r.code FROM fps_requested_atc r WHERE NOT EXISTS (
            SELECT 1 FROM fps_atc_ingredients i WHERE i.arm = r.arm AND i.code = r.code)")
        if (nrow(missingIngredients) || nrow(missingAtc)) {
            stop("Incomplete vocabulary definitions: ingredients ",
                 paste(missingIngredients$ingredientId, collapse = ", "),
                 "; ATC classes ", paste(missingAtc$code, collapse = ", "))
        }
        resolved <- query("SELECT arm, ingredient_id FROM fps_ingredients ORDER BY arm, ingredient_id")
        target <- resolved$ingredientId[resolved$arm == 1]
        comparator <- resolved$ingredientId[resolved$arm == 0]
        if (!length(target) || !length(comparator) || length(intersect(target, comparator))) {
            stop("Target and comparator must resolve to nonempty, disjoint ingredient sets")
        }
        if (specific) {
            roots <- query(paste0("SELECT concept_id FROM ", cdmDatabaseSchema,
                ".concept WHERE domain_id = 'Condition' AND standard_concept = 'S' AND concept_id IN (",
                paste(settings$indicationConceptIds, collapse = ","), ")"))
            if (!setequal(roots$conceptId, settings$indicationConceptIds)) stop("Missing indication concepts")
            execute("SpecificStudy.sql", form_policy = settings$formPolicy,
                    indication_concept_ids = settings$indicationConceptIds,
                    record_type_concept_ids = settings$recordTypeConceptIds,
                    min_age = settings$minAge, prior_days = settings$priorObservationDays,
                    indication_days = settings$indicationDays, washout_days = settings$washoutDays)
        } else {
            execute("DefaultStudy.sql")
        }
    }

    if (!public && query(paste0("SELECT count(*) AS n FROM information_schema.tables WHERE table_schema='",
        cdmDatabaseSchema, "' AND table_name='_fps_site_membership'"))$n > 0) {
        if (!specific) DatabaseConnector::executeSql(connection,
            "DELETE FROM fps_exposure e WHERE EXISTS (SELECT 1 FROM fps_exposure earlier
             WHERE earlier.subject_id=e.subject_id AND earlier.cohort_definition_id=e.cohort_definition_id
               AND earlier.cohort_start_date<e.cohort_start_date)", progressBar = FALSE)
        DatabaseConnector::executeSql(connection, paste0("DELETE FROM fps_exposure e WHERE NOT EXISTS (SELECT 1 FROM ",
            cdmDatabaseSchema, "._fps_site_membership m WHERE m.person_id=e.subject_id AND ",
            "e.cohort_start_date>=m.landmark_date)"), progressBar = FALSE)
    }

    # Use CohortMethod's cohort SQL on this connection so temporary cohorts are
    # visible to FeatureExtraction. getDbCohortMethodData opens its own connection.
    sql <- SqlRender::loadRenderTranslateSql("CreateOrCountCohorts.sql", packageName = "CohortMethod",
        dbms = "postgresql", cdm_database_schema = cdmDatabaseSchema,
        exposure_database_schema = "pg_temp", exposure_table = "fps_exposure",
        target_id = 1, comparator_id = 2, first_only = TRUE,
        remove_duplicate_subjects = "keep first, truncate to second",
        washout_period = settings$priorObservationDays,
        min_age = if (specific) "" else settings$minAge,
        restrict_to_common_period = FALSE, action = "CREATE")
    DatabaseConnector::executeSql(connection, sql, progressBar = FALSE)
    sql <- SqlRender::loadRenderTranslateSql("GetCohorts.sql", packageName = "CohortMethod",
        dbms = "postgresql", target_id = 1, cohortTable = "#cohort_person")
    cohorts <- query(sql)
    cohorts$rowId <- as.numeric(cohorts$rowId)
    if (anyNA(cohorts$rowId) || anyDuplicated(cohorts$rowId) || anyDuplicated(cohorts$personId)) {
        stop("Expected one row per person; inspect overlapping native observation periods")
    }
    counts <- c(target = sum(cohorts$treatment == 1), comparator = sum(cohorts$treatment == 0))
    message(study, " / ", settings$scenario, ": target = ", counts[[1]],
            ", comparator = ", counts[[2]])
    if (any(counts == 0)) stop("Both treatment groups are required; no automatic relaxation of study criteria")

    covariateSettings <- FeatureExtraction::createCovariateSettings(
        useDemographicsGender = TRUE, useDemographicsAgeGroup = TRUE,
        useConditionOccurrenceLongTerm = TRUE, useDrugExposureLongTerm = TRUE,
        useProcedureOccurrenceLongTerm = TRUE, useMeasurementLongTerm = TRUE,
        useConditionOccurrenceShortTerm = specific, useDrugExposureShortTerm = specific,
        useProcedureOccurrenceShortTerm = specific, useMeasurementShortTerm = specific,
        longTermStartDays = settings$longTermStartDays, shortTermStartDays = -30,
        endDays = settings$endDays,
        excludedCovariateConceptIds = sort(unique(c(target, comparator))),
        addDescendantsToExclude = TRUE)
    if (specific && !public) execute("StudyCovariates.sql", prior_days = settings$priorObservationDays)
    data <- FeatureExtraction::getDbCovariateData(connection = connection,
        cdmDatabaseSchema = if (specific && !public) "pg_temp" else cdmDatabaseSchema,
        cohortTable = "#cohort_person", cohortTableIsTemp = TRUE, rowIdField = "row_id",
        covariateSettings = covariateSettings)
    complete <- FALSE
    on.exit(if (!complete) Andromeda::close(data), add = TRUE)
    data$cohorts <- cohorts
    data$outcomes <- data.frame(rowId = numeric(), outcomeId = numeric(), daysToEvent = numeric())
    metadata <- attr(data, "metaData")
    metadata$targetId <- 1
    metadata$comparatorId <- 2
    metadata$studyDefinition <- settings
    if (public) {
        metadata$resolvedConcepts <- resolved
        metadata$resolvedConceptHash <- digest::digest(paste(resolved$arm, resolved$codesetId,
            resolved$conceptId, collapse = "\n"), algo = "sha256", serialize = FALSE)
        metadata$definitionHash <- settings$definitionHash
    } else metadata$resolvedIngredients <- resolved
    metadata$attrition <- rbind(attrition, data.frame(description = "Study-eligible subjects in native observation periods",
        targetPersons = counts[[1]], comparatorPersons = counts[[2]],
        targetExposures = counts[[1]], comparatorExposures = counts[[2]]))
    attr(data, "metaData") <- metadata
    class(data) <- "CohortMethodData"
    attr(class(data), "package") <- "CohortMethod"
    complete <- TRUE
    data
}
