# Cohort generation and feature preparation only. This script cannot fit a PS.
# Rscript extras/studies/PrepareStudies.R cohorts mimic [study]
# Rscript extras/studies/PrepareStudies.R cohorts synpuf [study]
# Rscript extras/studies/PrepareStudies.R features mimic|synpufA|synpufB [study]
library(FederatedPs)
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L) stop("Arguments: cohorts|features site [study]")
phase <- match.arg(args[1], c("cohorts", "features"))
site <- match.arg(args[2], c("mimic", "synpuf", "synpufA", "synpufB"))
virtualSite <- site %in% c("synpufA", "synpufB")
if (phase == "cohorts" && virtualSite) stop("Generate shared source cohorts with site synpuf, then extract each virtual site")
partition <- match.arg(Sys.getenv("FEDERATEDPS_PARTITION", "case"), c("case", "random"))
sourceSite <- if (site == "mimic") "mimic" else "synpuf"
if (!readRenviron(paste0(".Renviron.", sourceSite))) stop("Missing connection file")
connectionDetails <- DatabaseConnector::createConnectionDetails(dbms = "postgresql",
    server = paste(Sys.getenv("PGHOST"), Sys.getenv("PGDATABASE"), sep = "/"),
    port = as.integer(Sys.getenv("PGPORT")), user = Sys.getenv("PGUSER"), password = Sys.getenv("PGPASSWORD"))
schema <- switch(site, synpufA = "fps_sim_a", synpufB = "fps_sim_b", Sys.getenv("CDM_DATABASE_SCHEMA"))
if (virtualSite) {
    schema <- paste0(Sys.getenv("FEDERATEDPS_PARTITION_SCHEMA", "fps_sim"),
                     if (site == "synpufA") "_a" else "_b", if (partition == "random") "_random" else "")
}
resultsSchema <- paste0("fps_studies_", sourceSite)
connection <- DatabaseConnector::connect(connectionDetails)
DatabaseConnector::executeSql(connection, paste("CREATE SCHEMA IF NOT EXISTS", resultsSchema), progressBar = FALSE)
DatabaseConnector::disconnect(connection)
studies <- listStudies()
studies <- studies$study[studies$sourceType != "legacyPreset"]
if (length(args) > 2L) studies <- match.arg(args[3], studies)
root <- file.path("output", "studies", paste0(site, if (virtualSite && partition == "random") "_random" else ""))
dir.create(root, recursive = TRUE, showWarnings = FALSE)
writeLines(capture.output(utils::sessionInfo()), file.path(root, "sessionInfo.txt"))
implementationHash <- digest::digest(paste(deparse(FederatedPs::getDbStudyData),
    deparse(FederatedPs:::.resolveStudyConcepts), deparse(FederatedPs:::.preparePublicExposure),
    collapse = "\n"), algo = "sha256", serialize = FALSE)
# Reuse only byte-identical applied JSON from completed runs in this output
# directory / fixed CDM snapshot. Counts and every inclusion-statistics table
# are copied to the new registry ID; pair-selection remains study-specific.
cohortCache <- list()
if (phase == "cohorts") {
    for (marker in list.files(root, pattern = "^cohorts.json$", recursive = TRUE, full.names = TRUE)) {
        prior <- jsonlite::read_json(marker, simplifyVector = TRUE)
        if (!identical(prior$status, "complete") || !identical(prior$schema, schema)) next
        defs <- getStudyCohortDefinitions(prior$study, prior$scenario)
        if (!identical(prior$definitionHash, defs$definitionHash[1])) next
        for (i in seq_len(nrow(defs))) cohortCache[[digest::digest(defs$json[i], algo = "sha256")]] <- defs$cohortId[i]
    }
}
prepareCohorts <- function(study, scenario) {
    defs <- getStudyCohortDefinitions(study, scenario)
    connection <- DatabaseConnector::connect(connectionDetails)
    on.exit(DatabaseConnector::disconnect(connection))
    FederatedPs:::.checkStudySeeds(connection, schema, defs)
    tables <- CohortGenerator::getCohortTableNames("fps_cohort")
    CohortGenerator::createCohortTables(connection = connection, cohortDatabaseSchema = resultsSchema,
        cohortTableNames = tables, incremental = TRUE)
    for (i in seq_len(nrow(defs))) {
        hash <- digest::digest(defs$json[i], algo = "sha256")
        previousId <- cohortCache[[hash]]
        id <- defs$cohortId[i]
        if (!is.null(previousId)) {
            message("Reusing identical cohort JSON: ", previousId, " -> ", id)
            if (previousId != id) {
                for (table in unique(unlist(tables))) {
                    columns <- DatabaseConnector::querySql(connection, paste0("SELECT column_name FROM information_schema.columns WHERE table_schema='",
                        resultsSchema, "' AND table_name='", table, "' ORDER BY ordinal_position"))[[1]]
                    key <- columns[tolower(columns) == "cohort_definition_id"]
                    if (!length(key)) next
                    values <- columns
                    values[tolower(columns) == "cohort_definition_id"] <- as.character(id)
                    DatabaseConnector::executeSql(connection, paste0("DELETE FROM ", resultsSchema, ".", table,
                        " WHERE ", key, "=", id, "; INSERT INTO ", resultsSchema, ".", table,
                        " (", paste(columns, collapse = ","), ") SELECT ", paste(values, collapse = ","),
                        " FROM ", resultsSchema, ".", table, " WHERE ", key, "=", previousId), progressBar = FALSE)
                }
            }
        } else {
            CohortGenerator::generateCohortSet(connection = connection, cdmDatabaseSchema = schema,
                cohortDatabaseSchema = resultsSchema, cohortTableNames = tables,
                cohortDefinitionSet = defs[i, ], stopOnError = TRUE)
            cohortCache[[hash]] <<- id
        }
    }
    FederatedPs:::.recordStudyDefinition(connection, resultsSchema, "fps_cohort", defs)
}
for (study in studies) for (scenario in c("default", "studySpecific")) {
    directory <- file.path(root, study, scenario)
    dir.create(directory, recursive = TRUE, showWarnings = FALSE)
    marker <- file.path(directory, paste0(phase, ".json"))
    hash <- getStudySettings(study, scenario)$definitionHash
    if (file.exists(marker)) {
        old <- jsonlite::read_json(marker, simplifyVector = TRUE)
        if (identical(old$definitionHash, hash) && identical(old$status, "complete") &&
            (phase == "cohorts" || !identical(old$mode, "aggregated"))) next
        attempts <- file.path(directory, "attempts")
        dir.create(attempts, showWarnings = FALSE)
        file.copy(marker, file.path(attempts, paste0(phase, "_", format(Sys.time(), "%Y%m%dT%H%M%S"), ".json")))
    }
    start <- Sys.time()
    message("PREPARE ", phase, " / ", site, " / ", study, " / ", scenario)
    status <- tryCatch({
        if (phase == "cohorts") {
            prepareCohorts(study, scenario)
        } else {
            data <- getDbStudyData(connectionDetails, schema, study, scenario,
                cohortDatabaseSchema = resultsSchema, generateCohorts = FALSE)
            tryCatch({
                diagnostic <- describeStudyData(data)
                for (name in names(diagnostic)) utils::write.csv(diagnostic[[name]],
                    file.path(directory, paste0(name, ".csv")), row.names = FALSE)
                utils::write.csv(attr(data, "metaData")$attrition,
                    file.path(directory, "attrition.csv"), row.names = FALSE)
                utils::write.csv(attr(data, "metaData")$resolvedConcepts,
                    file.path(directory, "resolved_concepts.csv"), row.names = FALSE)
                CohortMethod::saveCohortMethodData(data, file.path(directory, "cohortMethodData"))
            }, finally = Andromeda::close(data))
        }
        list(status = "complete")
    }, error = function(e) {
        message("PREPARATION FAILED: ", conditionMessage(e))
        list(status = "failed", error = conditionMessage(e))
    })
    status <- c(status, list(study = study, scenario = scenario, site = site,
        definitionHash = hash, schema = schema, resultsSchema = resultsSchema,
        partition = if (virtualSite) partition else NULL,
        packageVersion = as.character(utils::packageVersion("FederatedPs")), implementationHash = implementationHash,
        started = format(start, tz = "UTC", usetz = TRUE),
        seconds = as.numeric(difftime(Sys.time(), start, units = "secs")),
        fitted = FALSE, matched = FALSE))
    jsonlite::write_json(status, marker, auto_unbox = TRUE, pretty = TRUE)
}
