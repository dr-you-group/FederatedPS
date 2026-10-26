# Archived SQL-generation recipe from 3c215a2 (before SQL-plan refactor).
# Database calls/validation were omitted; the rendering arguments are verbatim.
# This reference deliberately continues passing the old unused parameters.
referenceCareSiteSql <- function(schema, settings, careSiteId, patientLimit) {
    currentStep <- 0
    step <- function(...) NULL
    batches <- list()
    run <- function(sql, file) batches[[file]] <<- list(sql=sql,statements=SqlRender::splitSql(sql))
    execute <- function(file, ...) {
        path <- file.path("inst/sql/sql_server", file)
        if (!nzchar(path)) stop("Missing SQL Server templates; reinstall FederatedPs")
        sql <- paste(readLines(path, warn = FALSE), collapse = "\n")
        sql <- .fpsDbOperation(paste("Rendering", file),
            SqlRender::render(sql, cdm_database_schema = schema, care_site_id = careSiteId, ...),
            completed = currentStep)
        run(sql, file)
    }
    execute("SitePartition.sql")
    specific <- settings$scenario == "studySpecific"
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
    step(4, "Resolving study concept definitions")
    execute("StudyConcepts.sql", ingredient_rows = values(ingredients), atc_rows = values(atc, TRUE))
    if (specific) {
        execute("SpecificStudy.sql", form_policy = settings$formPolicy,
            indication_concept_ids = settings$indicationConceptIds,
            record_type_concept_ids = settings$recordTypeConceptIds, min_age = settings$minAge,
            prior_days = settings$priorObservationDays, indication_days = settings$indicationDays,
            washout_days = settings$washoutDays)
    } else execute("DefaultStudy.sql")
    if (patientLimit > 0L) {
        step(5, paste("Limiting exposure candidates to", patientLimit, "persons before CohortMethod"))
        execute("LimitPatients.sql", patient_limit = patientLimit)
    }
    step(6, "CohortMethod: preparing cohort SQL")
    sql <- .fpsDbOperation("CohortMethod: rendering CreateOrCountCohorts.sql",
        SqlRender::loadRenderTranslateSql("CreateOrCountCohorts.sql", packageName = "CohortMethod",
        dbms = "sql server", cdm_database_schema = schema,
        exposure_database_schema = "tempdb.dbo", exposure_table = "#fps_exposure",
        target_id = 1, comparator_id = 2, first_only = TRUE,
        remove_duplicate_subjects = "keep first, truncate to second",
        washout_period = settings$priorObservationDays, min_age = if (specific) "" else settings$minAge,
        restrict_to_common_period = FALSE, action = "CREATE"), completed = currentStep)
    # YUHS table names are uppercase (also works on case-insensitive databases).
    sql <- .fpsUppercaseCohortTables(sql, schema)
    step(6, "CohortMethod: executing cohort creation SQL")
    run(sql, "CohortMethod CreateOrCountCohorts.sql")
    step(6, "CohortMethod: preparing cohort fetch SQL")
    fetchSql <- .fpsDbOperation("CohortMethod: rendering GetCohorts.sql",
        SqlRender::loadRenderTranslateSql("GetCohorts.sql", packageName = "CohortMethod",
            dbms = "sql server", target_id = 1, cohortTable = "#cohort_person"), completed = currentStep)
    run(fetchSql,"CohortMethod GetCohorts.sql")
    execute("Covariates.sql",clinical_sql=.careSiteClinicalSql(schema,settings))
    batches
}
