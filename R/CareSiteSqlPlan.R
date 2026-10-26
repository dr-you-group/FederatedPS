# Render and split every clinical SQL template BEFORE opening a JDBC session.
# No database state is needed: concepts are resolved later by the prepared SQL.
.fpsSqlPlanRevision <- "sql-plan-4"

.fpsPrepareCareSiteSqlPlan <- function(schema, settings, careSiteId, patientLimit = 0L,
        templateRoot = system.file("sql", "sql_server", package = "FederatedPs"),
        render = SqlRender::render, split = SqlRender::splitSql,
        cohort = SqlRender::loadRenderTranslateSql) {
    .validateCdmSchema(schema)
    careSiteId <- .validateCareSiteId(careSiteId)
    patientLimit <- .validatePatientLimit(patientLimit)
    if (!nzchar(templateRoot) || !dir.exists(templateRoot)) stop("Missing SQL Server templates")
    specific <- identical(settings$scenario, "studySpecific")
    batches <- list()
    add <- function(name, sql) {
        statements <- .fpsDbOperation(paste("Splitting", name, "before DB connection"),
            split(sql), stage = "sql-prepare")
        if (!is.character(statements) || !length(statements) || anyNA(statements) ||
            any(!nzchar(trimws(statements)))) stop("Empty/invalid prepared SQL: ", name)
        batches[[name]] <<- list(sql = sql, statements = statements)
        .fpsDiagnosticWrite(paste0("prepared-", gsub("[^A-Za-z0-9_.-]", "-", name), ".sql"), sql)
    }
    prepare <- function(file, ...) {
        path <- file.path(templateRoot, file)
        sql <- paste(readLines(path, warn = FALSE), collapse = "\n")
        # Give SqlRender only the parameters present in this template. This
        # avoids unrelated missing-parameter warnings from the previous helper.
        parameters <- c(list(cdm_database_schema = schema, care_site_id = careSiteId), list(...))
        tokens <- regmatches(sql, gregexpr("@[A-Za-z_][A-Za-z0-9_]*", sql, perl = TRUE))[[1L]]
        parameters <- parameters[names(parameters) %in% sub("^@", "", tokens)]
        rendered <- .fpsDbOperation(paste("Rendering", file, "before DB connection"),
            do.call(render, c(list(sql = sql), parameters)), stage = "sql-prepare")
        add(file, rendered)
    }
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
    prepare("StudyConcepts.sql", ingredient_rows = values(ingredients), atc_rows = values(atc, TRUE))
    prepare("SitePartition.sql")
    if (length(batches[["SitePartition.sql"]]$statements) != 4L)
        stop("SitePartition must contain four prepared statements")
    if (!specific && patientLimit > 0L) prepare("LimitPartitionPatients.sql", patient_limit = patientLimit)
    prepare("SiteVisits.sql")
    prepare("StudyDrugs.sql")
    if (specific) prepare("SpecificStudy.sql", form_policy = settings$formPolicy,
        indication_concept_ids = settings$indicationConceptIds,
        record_type_concept_ids = settings$recordTypeConceptIds, min_age = settings$minAge,
        prior_days = settings$priorObservationDays, indication_days = settings$indicationDays,
        washout_days = settings$washoutDays) else prepare("DefaultStudy.sql")
    if (patientLimit > 0L) prepare("LimitPatients.sql", patient_limit = patientLimit)
    sql <- .fpsDbOperation("Rendering CohortMethod CreateOrCountCohorts.sql before DB connection",
        cohort("CreateOrCountCohorts.sql", packageName = "CohortMethod", dbms = "sql server",
            cdm_database_schema = schema, exposure_database_schema = "tempdb.dbo",
            exposure_table = "#fps_exposure", target_id = 1, comparator_id = 2, first_only = TRUE,
            remove_duplicate_subjects = "keep first, truncate to second",
            washout_period = settings$priorObservationDays, min_age = if (specific) "" else settings$minAge,
            restrict_to_common_period = FALSE, action = "CREATE"), stage = "sql-prepare")
    add("CohortMethod CreateOrCountCohorts.sql", .fpsUppercaseCohortTables(sql, schema))
    sql <- .fpsDbOperation("Rendering CohortMethod GetCohorts.sql before DB connection",
        cohort("GetCohorts.sql", packageName = "CohortMethod", dbms = "sql server",
            target_id = 1, cohortTable = "#cohort_person"), stage = "sql-prepare")
    add("CohortMethod GetCohorts.sql", sql)
    if (length(batches[["CohortMethod GetCohorts.sql"]]$statements) != 1L)
        stop("Cohort fetch must be one prepared SELECT")
    prepare("Covariates.sql", clinical_sql = .careSiteClinicalSql(schema, settings))
    plan <- list(revision = .fpsSqlPlanRevision, schema = schema, settings = settings,
        careSiteId = careSiteId, patientLimit = patientLimit, batches = batches)
    .fpsProgress("sql-ready", paste("Prepared", length(batches), "SQL files for site_id", careSiteId,
        "before DB connection; no clinical query has been sent"))
    plan
}

.fpsGetCareSiteSqlPlan <- function(schema, settings, careSiteId, patientLimit) {
    careSiteId <- .validateCareSiteId(careSiteId)
    patientLimit <- .validatePatientLimit(patientLimit)
    plans <- getOption("FederatedPs.careSiteSqlPlans")
    if (is.null(plans)) return(.fpsPrepareCareSiteSqlPlan(schema, settings, careSiteId, patientLimit))
    plan <- plans[[as.character(careSiteId)]]
    if (is.null(plan) || !identical(plan$revision, .fpsSqlPlanRevision) ||
        !identical(plan$schema, schema) || !identical(plan$settings, settings) ||
        !identical(plan$careSiteId, careSiteId) || !identical(plan$patientLimit, patientLimit))
        stop("Prepared SQL plan does not match this site's extraction settings; start a new run")
    plan
}
