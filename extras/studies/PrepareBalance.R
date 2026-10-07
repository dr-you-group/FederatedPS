# Preparation-only alternative for all-study feasibility: official
# FeatureExtraction aggregated mode, grouped by a common baseline window.
# Rscript extras/studies/PrepareBalance.R mimic|synpuf
# It saves prevalences/SMD, not fitting matrices. getDbStudyData remains the
# patient-level path for later experiments. Existing complete outputs are kept.
library(FederatedPs)
sourceSite <- match.arg(commandArgs(trailingOnly = TRUE)[1], c("mimic", "synpuf"))
readRenviron(paste0(".Renviron.", sourceSite))
details <- DatabaseConnector::createConnectionDetails(dbms = "postgresql",
    server = paste(Sys.getenv("PGHOST"), Sys.getenv("PGDATABASE"), sep = "/"),
    port = as.integer(Sys.getenv("PGPORT")), user = Sys.getenv("PGUSER"), password = Sys.getenv("PGPASSWORD"))
schema <- Sys.getenv("CDM_DATABASE_SCHEMA")
resultsSchema <- paste0("fps_studies_", sourceSite)
root <- file.path("output", "studies")
sites <- if (sourceSite == "mimic") "mimic" else c("synpufA", "synpufB")
execute <- function(cn, sql) DatabaseConnector::executeSql(cn, sql, progressBar = FALSE)
query <- function(cn, sql) DatabaseConnector::querySql(cn, sql, snakeCaseToCamelCase = TRUE)
cn <- DatabaseConnector::connect(details)
execute(cn, paste0("CREATE TABLE IF NOT EXISTS ", resultsSchema, ".fps_balance_population (",
    "cohort_definition_id integer, subject_id bigint, cohort_start_date date, cohort_end_date date, long_days integer); ",
    "CREATE INDEX IF NOT EXISTS fps_balance_population_idx ON ", resultsSchema,
    ".fps_balance_population(cohort_definition_id,subject_id)"))
DatabaseConnector::disconnect(cn)
tasks <- list()
catalog <- listStudies()
for (study in catalog$study[catalog$sourceType != "legacyPreset"]) for (scenario in c("default", "studySpecific")) {
    settings <- getStudySettings(study, scenario)
    hash <- settings$definitionHash
    directories <- stats::setNames(file.path(root, sites, study, scenario), sites)
    needed <- vapply(directories, function(directory) {
        marker <- file.path(directory, "features.json")
        if (!file.exists(marker)) return(TRUE)
        old <- jsonlite::read_json(marker, simplifyVector = TRUE)
        !(identical(old$status, "complete") && identical(old$definitionHash, hash))
    }, logical(1))
    if (!any(needed)) next
    cohortMarker <- file.path(root, sourceSite, study, scenario, "cohorts.json")
    if (!file.exists(cohortMarker)) next
    cohortRun <- jsonlite::read_json(cohortMarker, simplifyVector = TRUE)
    if (!identical(cohortRun$status, "complete") || !identical(cohortRun$definitionHash, hash)) {
        for (site in sites[needed]) {
            dir.create(directories[[site]], recursive = TRUE, showWarnings = FALSE)
            jsonlite::write_json(list(status = "blocked_cohort", study = study, scenario = scenario, site = site,
                definitionHash = hash, mode = "aggregated", error = cohortRun$error),
                file.path(directories[[site]], "features.json"), auto_unbox = TRUE, pretty = TRUE)
        }
        next
    }
    message("Preparing aggregate population: ", study, " / ", scenario)
    cn <- DatabaseConnector::connect(details)
    tryCatch({
        definitions <- getStudyCohortDefinitions(study, scenario)
        # The completed generation marker establishes these exact JSON hashes.
        FederatedPs:::.recordStudyDefinition(cn, resultsSchema, "fps_cohort", definitions)
        resolved <- FederatedPs:::.resolveStudyConcepts(cn, schema, definitions)
        FederatedPs:::.preparePublicExposure(cn, schema, resultsSchema, "fps_cohort", definitions,
            membershipSchema = if (sourceSite == "synpuf") "fps_sim" else NULL)
        sql <- SqlRender::loadRenderTranslateSql("CreateOrCountCohorts.sql", packageName = "CohortMethod",
            dbms = "postgresql", cdm_database_schema = schema,
            exposure_database_schema = "pg_temp", exposure_table = "fps_exposure",
            target_id = 1, comparator_id = 2, first_only = TRUE,
            remove_duplicate_subjects = "keep first, truncate to second",
            washout_period = settings$priorObservationDays,
            min_age = if (scenario == "default") settings$minAge else "",
            restrict_to_common_period = FALSE, action = "CREATE")
        execute(cn, sql)
        if (query(cn, "SELECT count(*)-count(DISTINCT subject_id) AS duplicates FROM cohort_person")$duplicates > 0) {
            stop("Overlapping native observation periods produce duplicate patients")
        }
        seeds <- unique(c(FederatedPs:::.exposureSeedIds(definitions$json[1]), FederatedPs:::.exposureSeedIds(definitions$json[2])))
        excluded <- unique(c(seeds, query(cn, paste0("SELECT descendant_concept_id FROM ", schema,
            ".concept_ancestor WHERE ancestor_concept_id IN (", paste(seeds, collapse = ","), ")"))$descendantConceptId))
        for (site in sites[needed]) {
            offset <- switch(site, mimic = 0L, synpufA = 10000000L, synpufB = 20000000L)
            ids <- definitions$cohortId + offset
            join <- if (site == "mimic") "" else paste0(" JOIN fps_sim.site_membership m ON m.person_id=c.subject_id AND m.site_id='", site, "'")
            execute(cn, paste0("DELETE FROM ", resultsSchema, ".fps_balance_population WHERE cohort_definition_id IN (",
                paste(ids, collapse = ","), "); INSERT INTO ", resultsSchema, ".fps_balance_population ",
                "SELECT CASE WHEN c.cohort_definition_id=1 THEN ", ids[1], " ELSE ", ids[2], " END,",
                "c.subject_id,c.cohort_start_date,c.cohort_start_date,", -settings$longTermStartDays,
                " FROM cohort_person c", join))
            counts <- query(cn, paste0("SELECT cohort_definition_id,count(*) AS n FROM ", resultsSchema,
                ".fps_balance_population WHERE cohort_definition_id IN (", paste(ids, collapse = ","), ") GROUP BY 1"))
            n <- counts$n[match(ids, counts$cohortDefinitionId)]; n[is.na(n)] <- 0
            dir.create(directories[[site]], recursive = TRUE, showWarnings = FALSE)
            utils::write.csv(resolved, file.path(directories[[site]], "resolved_concepts.csv"), row.names = FALSE)
            tasks[[length(tasks)+1L]] <- list(study = study, scenario = scenario, site = site, ids = ids,
                n = n, days = -settings$longTermStartDays, excluded = excluded,
                directory = directories[[site]], definitionHash = hash)
        }
    }, error = function(e) {
        message("Population preparation failed: ", conditionMessage(e))
        for (site in sites[needed]) {
            dir.create(directories[[site]], recursive = TRUE, showWarnings = FALSE)
            jsonlite::write_json(list(status = "failed", study = study, scenario = scenario, site = site,
                definitionHash = hash, mode = "aggregated", error = conditionMessage(e)),
                file.path(directories[[site]], "features.json"), auto_unbox = TRUE, pretty = TRUE)
        }
    }, finally = DatabaseConnector::disconnect(cn))
}
for (days in unique(vapply(tasks, `[[`, numeric(1), "days"))) {
    batch <- Filter(function(task) task$days == days, tasks)
    cn <- DatabaseConnector::connect(details)
    table <- paste0("fps_balance_", days)
    execute(cn, paste0("CREATE OR REPLACE VIEW ", resultsSchema, ".", table,
        " AS SELECT cohort_definition_id,subject_id,cohort_start_date,cohort_end_date FROM ",
        resultsSchema, ".fps_balance_population WHERE long_days=", days))
    settings <- FeatureExtraction::createCovariateSettings(useDemographicsGender = TRUE,
        useDemographicsAgeGroup = TRUE, useConditionOccurrenceLongTerm = TRUE,
        useDrugExposureLongTerm = TRUE, useProcedureOccurrenceLongTerm = TRUE, useMeasurementLongTerm = TRUE,
        useConditionOccurrenceShortTerm = days != 90, useDrugExposureShortTerm = days != 90,
        useProcedureOccurrenceShortTerm = days != 90, useMeasurementShortTerm = days != 90,
        longTermStartDays = -days, shortTermStartDays = -30, endDays = -1)
    started <- Sys.time()
    message("Official aggregated FeatureExtraction: ", sourceSite, " / ", days, " days / ", length(batch), " study-site tasks")
    data <- FeatureExtraction::getDbCovariateData(connection = cn, cdmDatabaseSchema = schema,
        cohortDatabaseSchema = resultsSchema, cohortTable = table,
        cohortIds = unlist(lapply(batch, `[[`, "ids")), covariateSettings = settings,
        aggregated = TRUE, minCharacterizationMean = 0, minCharacterizationCount = 0)
    tryCatch({
        covariates <- dplyr::collect(data$covariates)
        reference <- merge(dplyr::collect(data$covariateRef), dplyr::collect(data$analysisRef), by = "analysisId")
        if (!"averageValue" %in% names(covariates)) stop("Unexpected FeatureExtraction aggregate schema")
        elapsed <- as.numeric(difftime(Sys.time(), started, units = "secs"))
        for (task in batch) {
            values <- covariates[covariates$cohortDefinitionId %in% task$ids, ]
            r <- reference[reference$covariateId %in% values$covariateId & !reference$conceptId %in% task$excluded, ]
            for (arm in 1:2) {
                a <- values[values$cohortDefinitionId == task$ids[arm], ]
                prevalence <- a$averageValue[match(r$covariateId, a$covariateId)]
                prevalence[is.na(prevalence)] <- 0
                prefix <- c("target", "comparator")[arm]
                r[[paste0(prefix, "Prevalence")]] <- prevalence
                r[[paste0(prefix, "Count")]] <- round(prevalence * task$n[arm])
            }
            r$smdDenominator <- sqrt((r$targetPrevalence*(1-r$targetPrevalence)+r$comparatorPrevalence*(1-r$comparatorPrevalence))/2)
            delta <- abs(r$targetPrevalence-r$comparatorPrevalence)
            r$absoluteSmd <- if (any(task$n == 0)) NA_real_ else ifelse(delta == 0, 0, delta/r$smdDenominator)
            r <- r[order(r$covariateId), ]
            utils::write.csv(r, file.path(task$directory, "covariates.csv"), row.names = FALSE)
            utils::write.csv(data.frame(targetPersons=task$n[1], comparatorPersons=task$n[2], features=nrow(r),
                nonzero=sum(r$targetCount+r$comparatorCount), maxAbsoluteSmd=if (nrow(r)) max(r$absoluteSmd) else NA,
                meanAbsoluteSmd=mean(r$absoluteSmd), abovePointOne=sum(r$absoluteSmd>0.1)),
                file.path(task$directory, "counts.csv"), row.names = FALSE)
            jsonlite::write_json(list(status=if (any(task$n==0)) "empty_arm" else "complete", study=task$study,
                scenario=task$scenario, site=task$site, definitionHash=task$definitionHash,
                mode="aggregated", seconds=elapsed, sharedBatch=paste(sourceSite,days,sep="_"),
                runtimeScope="Shared FeatureExtraction batch; do not sum across studies", fitted=FALSE,matched=FALSE),
                file.path(task$directory,"features.json"),auto_unbox=TRUE,pretty=TRUE)
        }
    }, finally = {Andromeda::close(data); DatabaseConnector::disconnect(cn)})
}
