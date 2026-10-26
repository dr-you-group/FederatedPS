# SQL Server care-site extraction is deliberately explicit: filtering the cohort
# alone would still let FeatureExtraction read visits from other institutions.
.validateCdmSchema <- function(schema) {
    if (length(schema) != 1L || is.na(schema) ||
        !grepl("^[A-Za-z_][A-Za-z0-9_]*([.][A-Za-z_][A-Za-z0-9_]*)?$", schema))
        stop("Use an unquoted schema or database.schema identifier")
    invisible(schema)
}

.validateCareSiteId <- function(id) {
    if (length(id) != 1L || is.na(id) || !grepl("^[0-9]+$", as.character(id)) ||
        as.numeric(id) < 1 || as.numeric(id) > .Machine$integer.max)
        stop("careSiteId must be one positive integer from CARE_SITE (not CARE_SITE_SOURCE_VALUE)")
    as.integer(id)
}

.validatePatientLimit <- function(limit) {
    if (!is.numeric(limit) || length(limit) != 1L || is.na(limit) || !is.finite(limit) ||
        limit != floor(limit) || limit < 0 || limit == 1 || limit > .Machine$integer.max)
        stop("patientLimit must be zero (unlimited) or an integer of at least two per site")
    as.integer(limit)
}

.careSiteAnalysis <- function(settings) {
    result <- data.frame(analysisId = c(1L, 2L),
        analysisName = c("Gender", "Age in five-year groups (index year minus birth year)"),
        domainId = c("Demographics", "Demographics"), startDay = NA_integer_, endDay = NA_integer_)
    for (window in c("long", if (settings$scenario == "studySpecific") "short")) {
        result <- rbind(result, data.frame(analysisId = c(100L, 200L, 300L, 400L) +
            if (window == "long") 1L else 2L,
            analysisName = paste(c("Condition", "Drug", "Procedure", "Measurement"), window, "site-linked binary occurrence"),
            domainId = c("Condition", "Drug", "Procedure", "Measurement"),
            startDay = if (window == "long") settings$longTermStartDays else -30L, endDay = -1L))
    }
    result$isBinary <- "Y"
    result$missingMeansZero <- "Y"
    result
}

.careSiteClinicalSql <- function(schema, settings) {
    .validateCdmSchema(schema)
    domains <- list(c("CONDITION_OCCURRENCE", "condition_concept_id", "condition_start_date"),
                    c("DRUG_EXPOSURE", "drug_concept_id", "drug_exposure_start_date"),
                    c("PROCEDURE_OCCURRENCE", "procedure_concept_id", "procedure_date"),
                    c("MEASUREMENT", "measurement_concept_id", "measurement_date"))
    analysis <- .careSiteAnalysis(settings)
    sql <- character()
    for (i in 3:nrow(analysis)) {
        a <- analysis[i, ]
        d <- domains[[a$analysisId %/% 100L]]
        sql <- c(sql, sprintf("SELECT DISTINCT c.row_id,
            CAST(d.%s AS BIGINT) * 1000 + %d AS covariate_id, CAST(1 AS FLOAT) AS covariate_value
            FROM #cohort_person c
            JOIN %s.%s d ON d.person_id = c.subject_id
            JOIN #fps_visit v ON v.visit_occurrence_id = d.visit_occurrence_id AND v.person_id = d.person_id
            JOIN #fps_cutoff cutoff ON cutoff.subject_id = c.subject_id
            WHERE d.%s > 0 AND d.%s BETWEEN DATEADD(DAY, %d, c.cohort_start_date) AND DATEADD(DAY, -1, c.cohort_start_date)
              AND d.%s < cutoff.covariate_cutoff
              AND NOT EXISTS (SELECT 1 FROM #fps_excluded x WHERE x.concept_id = d.%s)",
            d[2], a$analysisId, schema, d[1], d[2], d[3], a$startDay, d[3], d[2]))
    }
    paste(sql, collapse = "\nUNION ALL\n")
}

.getCareSiteStudyData <- function(connection, schema, settings, careSiteId, patientLimit = 0L, sqlPlan) {
    careSiteId <- .validateCareSiteId(careSiteId)
    patientLimit <- .validatePatientLimit(patientLimit)
    .validateCdmSchema(schema)
    currentStep <- 0
    currentDetail <- "Preparing extraction"
    step <- function(done, detail) {
        currentStep <<- done
        currentDetail <<- detail
        .fpsProgress("extract", detail, done, 10, "extraction steps (not time)")
    }
    query <- function(sql, label = currentDetail, smallColumns = NULL) {
        .fpsDbOperation(paste(label, "query and fetch"), {
            if (is.null(smallColumns)) .fpsQuerySqlServer(connection, sql)
            else .fpsSmallSqlQuery(connection, sql, smallColumns)
        }, sql = sql, completed = currentStep)
    }
    execute <- function(file) {
        batch <- sqlPlan$batches[[file]]
        if (is.null(batch)) stop("Missing prepared SQL: ", file)
        .fpsProgress("extract", paste("Using prepared", file, "(", length(batch$statements), "statements)"),
            currentStep, 10, "extraction steps (not time)")
        .fpsExecuteSql(connection, batch$sql, file, completed = currentStep, statements = batch$statements)
    }
    if (!is.null(getOption("FederatedPs.smallQueryTimeoutSeconds"))) {
        step(0, "Connection self-check (SELECT 1 and session ID)")
        check <- query("SELECT CAST(1 AS INT) AS ok, @@SPID AS session_id",
            smallColumns = c(ok = "integer", sessionId = "integer"))
        if (nrow(check) != 1L || is.na(check$ok[1]) || check$ok[1] != 1L ||
            is.na(check$sessionId[1])) stop("Unexpected SQL Server self-check result")
        .fpsDiagnosticWrite("connection.tsv", paste(
            format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC"),
            Sys.getpid(), check$sessionId[1], sep = "\t"), append = TRUE)
        .fpsProgress("connected", paste("SQL Server self-check passed; SPID", check$sessionId[1],
                                        "; R PID", Sys.getpid()))
    }
    step(0, "CARE_SITE lookup")
    institution <- query(sprintf("SELECT TOP (2) care_site_id, care_site_name, care_site_source_value FROM %s.CARE_SITE WHERE care_site_id = %d", schema, careSiteId),
        smallColumns = c(careSiteId = "integer", careSiteName = "character", careSiteSourceValue = "character"))
    if (nrow(institution) != 1L) stop("Expected one CARE_SITE row for careSiteId ", careSiteId)
    .fpsSetClinicalNetworkTimeout(connection)
    .fpsDbStartupState("Connection self-check and CARE_SITE validation passed", ready = TRUE)
    step(1, "SitePartition.sql: assigning exclusive patients and visits")
    execute("SitePartition.sql")
    step(2, "Counting site partition results")
    partition <- query(sprintf("SELECT
        (SELECT COUNT_BIG(*) FROM #fps_person) AS exclusive_persons,
        (SELECT COUNT_BIG(*) FROM #fps_visit) AS linked_visits,
        (SELECT COUNT_BIG(*) FROM #fps_membership WHERE care_site_id <> last_care_site_id) AS multisite_persons_all_cdm,
        (SELECT COUNT_BIG(*) FROM %s.VISIT_OCCURRENCE WHERE care_site_id IS NULL OR care_site_id <= 0) AS unattributed_visits_all_cdm", schema))
    if (partition$exclusivePersons == 0) stop("No patients with visits exclusive to careSiteId ", careSiteId)
    message("Exclusive persons: ", partition$exclusivePersons, "; linked visits: ", partition$linkedVisits,
        "; multisite persons excluded (whole CDM): ", partition$multisitePersonsAllCdm)
    domains <- c("DRUG_EXPOSURE", "CONDITION_OCCURRENCE", "PROCEDURE_OCCURRENCE", "MEASUREMENT")
    linkage <- do.call(rbind, lapply(domains, function(table) {
        step(3, paste("Auditing visit linkage:", table))
        counts <- query(sprintf("SELECT COUNT_BIG(*) AS candidate_records,
            COALESCE(SUM(CAST(CASE WHEN v.visit_occurrence_id IS NULL THEN 1 ELSE 0 END AS BIGINT)), 0) AS excluded_records
            FROM %s.%s d JOIN #fps_person p ON p.person_id = d.person_id
            LEFT JOIN #fps_visit v ON v.visit_occurrence_id = d.visit_occurrence_id AND v.person_id = d.person_id", schema, table))
        message(table, ": ", counts$excludedRecords, " / ", counts$candidateRecords,
            " records excluded by visit linkage")
        data.frame(table = table, counts)
    }))
    specific <- settings$scenario == "studySpecific"
    step(4, "Resolving study concept definitions")
    execute("StudyConcepts.sql")
    missing <- query(sprintf("SELECT r.ingredient_id FROM #fps_requested_ingredients r WHERE NOT EXISTS (
        SELECT 1 FROM %s.CONCEPT c WHERE c.concept_id = r.ingredient_id
        AND c.concept_class_id = 'Ingredient' AND c.vocabulary_id IN ('RxNorm', 'RxNorm Extension'))", schema))
    missingAtc <- query("SELECT r.code FROM #fps_requested_atc r WHERE NOT EXISTS (
        SELECT 1 FROM #fps_atc_ingredients i WHERE i.arm = r.arm AND i.code = r.code)")
    if (nrow(missing) || nrow(missingAtc)) stop("Incomplete ingredient/ATC vocabulary definitions")
    resolved <- query("SELECT arm, ingredient_id FROM #fps_ingredients ORDER BY arm, ingredient_id")
    target <- resolved$ingredientId[resolved$arm == 1]
    comparator <- resolved$ingredientId[resolved$arm == 0]
    if (!length(target) || !length(comparator) || length(intersect(target, comparator)))
        stop("Target and comparator must resolve to nonempty, disjoint ingredient sets")
    step(5, "Building study exposures")
    if (specific) {
        roots <- query(sprintf("SELECT concept_id FROM %s.CONCEPT WHERE domain_id = 'Condition'
            AND standard_concept = 'S' AND concept_id IN (%s)", schema, paste(settings$indicationConceptIds, collapse = ",")))
        if (!setequal(roots$conceptId, settings$indicationConceptIds)) stop("Missing indication concepts")
        execute("SpecificStudy.sql")
    } else execute("DefaultStudy.sql")
    if (patientLimit > 0L) {
        step(5, paste("Limiting exposure candidates to", patientLimit, "persons before CohortMethod"))
        execute("LimitPatients.sql")
    }
    step(6, "CohortMethod: executing prepared cohort creation SQL")
    execute("CohortMethod CreateOrCountCohorts.sql")
    fetchSql <- sqlPlan$batches[["CohortMethod GetCohorts.sql"]]$statements
    step(6, "CohortMethod: fetching cohort rows into R")
    cohorts <- query(fetchSql, "CohortMethod GetCohorts.sql")
    step(6, "CohortMethod: validating cohort rows in R")
    cohorts$rowId <- as.numeric(cohorts$rowId)
    if (anyNA(cohorts$rowId) || anyDuplicated(cohorts$rowId) || anyDuplicated(cohorts$personId))
        stop("Expected one row per person; inspect native observation periods")
    if (patientLimit > 0L && nrow(cohorts) > patientLimit) stop("Patient cap was exceeded")
    counts <- c(target = sum(cohorts$treatment == 1), comparator = sum(cohorts$treatment == 0))
    message("care_site_id ", careSiteId, ": target = ", counts[1], ", comparator = ", counts[2])
    if (any(counts == 0)) stop("Both treatment groups are required; study criteria were not relaxed")
    step(7, "Covariates.sql: extracting site-linked clinical features")
    execute("Covariates.sql")
    data <- Andromeda::andromeda()
    complete <- FALSE
    on.exit(if (!complete) Andromeda::close(data), add = TRUE)
    step(8, "Transferring covariates to local Andromeda")
    transferSql <- "SELECT row_id, covariate_id, covariate_value FROM #fps_covariates"
    .fpsDbOperation("Transferring covariates into Andromeda",
        .fpsCopySqlServerToAndromeda(connection, transferSql, data, "covariates"),
        sql = transferSql, completed = currentStep)
    step(9, "Transferring feature metadata")
    metadataSql <- sprintf("SELECT DISTINCT f.covariate_id,
        f.covariate_id %% 1000 AS analysis_id,
        CASE WHEN f.covariate_id %% 1000 = 2 THEN 0 ELSE f.covariate_id / 1000 END AS concept_id,
        CASE WHEN f.covariate_id %% 1000 = 2 THEN CONCAT('Age group ', CAST(f.covariate_id / 1000 * 5 AS VARCHAR(20)))
             ELSE COALESCE(c.concept_name, 'Unknown concept') END AS covariate_name
        FROM #fps_covariates f LEFT JOIN %s.CONCEPT c ON c.concept_id = f.covariate_id / 1000", schema)
    .fpsDbOperation("Transferring feature metadata into Andromeda",
        .fpsCopySqlServerToAndromeda(connection, metadataSql, data, "covariateRef"),
        sql = metadataSql, completed = currentStep)
    data$analysisRef <- .careSiteAnalysis(settings)
    data$cohorts <- cohorts
    data$outcomes <- data.frame(rowId = numeric(), outcomeId = numeric(), daysToEvent = numeric())
    # Shared model contract must not include an institution's ID or name.
    settings$definitionVersion <- 2L
    settings$exposureSource <- "visit-linked drug_exposure (not pooled drug_era)"
    settings$featureDefinition <- "care-site-binary-v1"
    settings$partitionPolicy <- "exclude persons visiting multiple positive care_site_ids"
    attr(data, "metaData") <- list(targetId = 1, comparatorId = 2, studyDefinition = settings,
        patientLimit = patientLimit, samplingPolicy = if (patientLimit > 0L)
            "deterministic alternating earliest-exposure arms before CohortMethod; smoke test only" else "all candidates",
        resolvedIngredients = resolved, careSite = institution, sitePartition = partition,
        recordLinkage = linkage, attrition = data.frame(description = "Site-local study-eligible subjects",
            targetPersons = counts[1], comparatorPersons = counts[2],
            targetExposures = counts[1], comparatorExposures = counts[2]))
    class(data) <- "CohortMethodData"
    attr(class(data), "package") <- "CohortMethod"
    complete <- TRUE
    step(10, "Extraction complete")
    data
}
