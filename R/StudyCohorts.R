.publicStudyDefinitions <- function() {
    path <- system.file("studies", "registry.json", package = "FederatedPs")
    if (!nzchar(path)) return(list())
    definitions <- jsonlite::fromJSON(path, simplifyVector = FALSE)
    stats::setNames(definitions, vapply(definitions, `[[`, character(1), "study"))
}

.studyJson <- function(study, scenario, arm) {
    path <- system.file("studies", "cohorts", study, paste0(scenario, "_", arm, ".json"),
                        package = "FederatedPs")
    if (!nzchar(path)) stop("No ATLAS cohort JSON for this study/scenario")
    paste(readLines(path, warn = FALSE), collapse = "\n")
}

.studyJsonHash <- function(study, scenario) {
    digest::digest(paste(.studyJson(study, scenario, "target"),
                         .studyJson(study, scenario, "comparator"), sep = "\n"),
                   algo = "sha256", serialize = FALSE)
}

.exposureSeedIds <- function(json) {
    expression <- jsonlite::fromJSON(json, simplifyVector = FALSE)
    event <- expression$PrimaryCriteria$CriteriaList[[1]][[1]]
    set <- Filter(function(x) x$id == event$CodesetId, expression$ConceptSets)[[1]]
    as.numeric(vapply(Filter(function(x) !isTRUE(x$isExcluded), set$expression$items),
                      function(x) x$concept$CONCEPT_ID, numeric(1)))
}

.studyIdentifier <- function(x) {
    if (length(x) != 1L || is.na(x) || !grepl("^[A-Za-z_][A-Za-z0-9_]*$", x)) {
        stop("Use an unquoted PostgreSQL identifier")
    }
    x
}

.requireStudyPackages <- function(atlas = FALSE) {
    packages <- if (atlas) "ROhdsiWebApi" else c("CirceR", "CohortGenerator")
    for (package in packages) if (!requireNamespace(package, quietly = TRUE)) {
        stop("Install the optional OHDSI package ", package, " to use this operation")
    }
}

#' Get the executable ATLAS cohort definitions for a public study
#'
#' @param study Public study ID from [listStudies()].
#' @param scenario `default` or `studySpecific`.
#' @return A CohortGenerator definition data frame containing cohortId,
#'   cohortName, json, sql and definitionHash. JSON and SQL describe the same
#'   applied cohort. Original sources are bundled separately under studies/source.
#' @export
getStudyCohortDefinitions <- function(study, scenario = c("default", "studySpecific")) {
    .requireStudyPackages()
    scenario <- match.arg(scenario)
    settings <- getStudySettings(study, scenario)
    if (is.null(settings$sourceType)) stop("Legacy presets retain their R/SQL execution path")
    json <- vapply(c("target", "comparator"), function(arm) .studyJson(study, scenario, arm), character(1))
    sql <- vapply(json, function(x) CirceR::buildCohortQuery(
        CirceR::cohortExpressionFromJson(x), CirceR::createGenerateOptions(generateStats = TRUE)), character(1))
    offset <- if (scenario == "default") 100000L else 0L
    data.frame(cohortId = as.integer(c(settings$targetId, settings$comparatorId)) + offset,
        cohortName = paste("FPS", study, scenario, paste0("v", settings$definitionVersion),
                           c("target", "comparator"), sep = " / "),
        json = unname(json), sql = unname(sql), definitionHash = settings$definitionHash,
        stringsAsFactors = FALSE)
}

.generateStudyCohorts <- function(connection, cdmDatabaseSchema, cohortDatabaseSchema,
                                  cohortTable, study, scenario) {
    .studyIdentifier(cdmDatabaseSchema)
    .studyIdentifier(cohortDatabaseSchema)
    .studyIdentifier(cohortTable)
    definitions <- getStudyCohortDefinitions(study, scenario)
    .checkStudySeeds(connection, cdmDatabaseSchema, definitions)
    tables <- CohortGenerator::getCohortTableNames(cohortTable = cohortTable)
    CohortGenerator::createCohortTables(connection = connection,
        cohortDatabaseSchema = cohortDatabaseSchema, cohortTableNames = tables, incremental = TRUE)
    generated <- CohortGenerator::generateCohortSet(connection = connection,
        cdmDatabaseSchema = cdmDatabaseSchema, cohortDatabaseSchema = cohortDatabaseSchema,
        cohortTableNames = tables, cohortDefinitionSet = definitions, stopOnError = TRUE)
    .recordStudyDefinition(connection, cohortDatabaseSchema, cohortTable, definitions)
    attr(generated, "definitions") <- definitions[, c("cohortId", "cohortName", "definitionHash")]
    generated
}

.recordStudyDefinition <- function(connection, schema, table, definitions) {
    name <- paste0(schema, ".", table, "_definition")
    DatabaseConnector::executeSql(connection, paste0("CREATE TABLE IF NOT EXISTS ", name,
        " (cohort_definition_id integer PRIMARY KEY, definition_hash varchar(64) NOT NULL)"), progressBar = FALSE)
    for (i in seq_len(nrow(definitions))) {
        hash <- digest::digest(definitions$json[i], algo = "sha256", serialize = FALSE)
        DatabaseConnector::executeSql(connection, paste0("INSERT INTO ", name, " VALUES (",
            definitions$cohortId[i], ",'", hash, "') ON CONFLICT (cohort_definition_id) DO UPDATE SET ",
            "definition_hash=EXCLUDED.definition_hash"), progressBar = FALSE)
    }
}

.checkStoredStudyDefinition <- function(connection, schema, table, definitions) {
    saved <- DatabaseConnector::querySql(connection, paste0("SELECT cohort_definition_id, definition_hash FROM ",
        schema, ".", table, "_definition WHERE cohort_definition_id IN (",
        paste(definitions$cohortId, collapse = ","), ")"), snakeCaseToCamelCase = TRUE)
    expected <- vapply(definitions$json, digest::digest, character(1), algo = "sha256", serialize = FALSE)
    found <- saved$definitionHash[match(definitions$cohortId, saved$cohortDefinitionId)]
    if (anyNA(found) || !identical(unname(expected), unname(found))) {
        stop("Stored cohort definition differs or is not recorded; regenerate cohorts with this package version")
    }
}

.checkStudySeeds <- function(connection, schema, definitions) {
    seeds <- unique(unlist(lapply(definitions$json, function(json) {
        expression <- jsonlite::fromJSON(json, simplifyVector = FALSE)
        unlist(lapply(expression$ConceptSets, function(set) lapply(set$expression$items,
            function(item) item$concept$CONCEPT_ID)))
    })))
    available <- DatabaseConnector::querySql(connection, paste0("SELECT concept_id FROM ", schema,
        ".concept WHERE concept_id IN (", paste(seeds, collapse = ","), ")"), snakeCaseToCamelCase = TRUE)$conceptId
    missing <- setdiff(seeds, available)
    if (length(missing)) stop("Vocabulary is missing cohort concept seeds (including exclusions): ",
                               paste(missing, collapse = ","))
}

#' Generate a public study's cohorts without fitting propensity scores
#'
#' @param connectionDetails PostgreSQL connection details.
#' @param cdmDatabaseSchema CDM schema, including a virtual-site view schema.
#' @param cohortDatabaseSchema Existing writable analysis schema, separate from CDM.
#' @param cohortTable Cohort table prefix; CohortGenerator also creates diagnostic tables.
#' @param study Public study ID.
#' @param scenario `default` or `studySpecific`.
#' @return CohortGenerator generation status with definition metadata.
#' @details Writes only to the supplied analysis schema. Patient-level tables are
#'   local artifacts. Generation does not apply the virtual-site landmark or the
#'   pairwise tie/first-person rules; [getDbStudyData()] applies those final rules.
#' @export
generateStudyCohorts <- function(connectionDetails, cdmDatabaseSchema,
                                 cohortDatabaseSchema, study,
                                 scenario = c("default", "studySpecific"),
                                 cohortTable = "fps_cohort") {
    scenario <- match.arg(scenario)
    if (identical(cdmDatabaseSchema, cohortDatabaseSchema)) stop("Use a separate analysis schema")
    connection <- DatabaseConnector::connect(connectionDetails)
    on.exit(DatabaseConnector::disconnect(connection))
    .generateStudyCohorts(connection, cdmDatabaseSchema, cohortDatabaseSchema, cohortTable, study, scenario)
}

.resolveStudyConcepts <- function(connection, schema, definitions) {
    .checkStudySeeds(connection, schema, definitions)
    rows <- list()
    for (i in seq_len(nrow(definitions))) {
        expression <- jsonlite::fromJSON(definitions$json[i], simplifyVector = FALSE)
        for (set in expression$ConceptSets) {
            sql <- CirceR::buildConceptSetQuery(as.character(jsonlite::toJSON(set$expression, auto_unbox = TRUE, null = "null")))
            sql <- SqlRender::render(sql, vocabulary_database_schema = schema)
            sql <- SqlRender::translate(sql, targetDialect = "postgresql")
            ids <- DatabaseConnector::querySql(connection, sql, snakeCaseToCamelCase = TRUE)$conceptId
            if (!length(ids)) stop("Empty resolved concept set: ", set$name,
                                   "; inspect this site's vocabulary before extraction")
            rows[[length(rows) + 1L]] <- data.frame(arm = if (i == 1L) "target" else "comparator",
                codesetId = set$id, conceptId = as.numeric(ids), stringsAsFactors = FALSE)
        }
    }
    result <- do.call(rbind, rows)
    result <- result[order(result$arm, result$codesetId, result$conceptId), ]
    rownames(result) <- NULL
    result
}

.preparePublicExposure <- function(connection, schema, cohortSchema, cohortTable, definitions,
                                   membershipSchema = NULL) {
    query <- function(sql) DatabaseConnector::querySql(connection, sql, snakeCaseToCamelCase = TRUE)
    membership <- query(paste0("SELECT count(*) AS n FROM information_schema.tables WHERE table_schema = '",
        schema, "' AND table_name = '_fps_site_membership'"))$n > 0
    # View schemas retain the person's complete history. Only index is restricted.
    membershipTable <- if (!is.null(membershipSchema)) paste0(.studyIdentifier(membershipSchema), ".site_membership") else
        if (membership) paste0(schema, "._fps_site_membership") else NULL
    restriction <- if (!is.null(membershipTable)) paste0("AND EXISTS (SELECT 1 FROM ", membershipTable,
        " m WHERE m.person_id = c.subject_id AND c.cohort_start_date >= m.landmark_date)") else ""
    table <- paste(cohortSchema, cohortTable, sep = ".")
    ids <- definitions$cohortId
    sql <- paste0("CREATE TEMP TABLE fps_raw_cohort AS SELECT DISTINCT subject_id, cohort_definition_id, ",
        "cohort_start_date, cohort_end_date FROM ", table, " c WHERE cohort_definition_id IN (", paste(ids, collapse = ","), ") ",
        "AND EXISTS (SELECT 1 FROM ", schema, ".person p WHERE p.person_id=c.subject_id);",
        "CREATE TEMP TABLE fps_site_cohort AS SELECT c.* FROM fps_raw_cohort c WHERE TRUE ", restriction, ";",
        "CREATE INDEX ON fps_site_cohort(subject_id,cohort_start_date); ANALYZE fps_site_cohort;",
        "CREATE TEMP TABLE fps_untied_cohort AS SELECT c.* FROM fps_site_cohort c WHERE NOT EXISTS (",
        "SELECT 1 FROM fps_site_cohort d WHERE d.subject_id=c.subject_id AND d.cohort_start_date=c.cohort_start_date ",
        "AND d.cohort_definition_id<>c.cohort_definition_id);",
        "CREATE TEMP TABLE fps_exposure AS SELECT subject_id, CASE WHEN cohort_definition_id=", ids[1],
        " THEN 1 ELSE 2 END AS cohort_definition_id, cohort_start_date, cohort_end_date FROM (",
        "SELECT *, row_number() OVER (PARTITION BY subject_id ORDER BY cohort_start_date, cohort_definition_id) AS seq ",
        "FROM fps_untied_cohort) x WHERE seq=1; CREATE UNIQUE INDEX ON fps_exposure(subject_id)")
    DatabaseConnector::executeSql(connection, sql, progressBar = FALSE)
    result <- lapply(c("fps_raw_cohort", "fps_site_cohort", "fps_untied_cohort", "fps_exposure"), function(name) {
        armIds <- if (name == "fps_exposure") c(1L, 2L) else ids
        data <- query(paste0("SELECT cohort_definition_id, count(DISTINCT subject_id) AS n FROM ", name, " GROUP BY 1"))
        counts <- data$n[match(armIds, data$cohortDefinitionId)]
        counts[is.na(counts)] <- 0
        data.frame(description = name, targetPersons = counts[1], comparatorPersons = counts[2],
                   targetExposures = counts[1], comparatorExposures = counts[2])
    })
    do.call(rbind, result)
}
