args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 2L)
config <- jsonlite::fromJSON(args[1])
role <- args[2]
out <- file.path(config$output, role)
source(file.path(config$project, "windows", "progress.R"))
options(FederatedPs.progress = fp_start_progress(out, role,
    historyDirectory = file.path(config$project, "work", "progress-history")))
progress <- function(stage, detail = "") utils::getFromNamespace(".fpsProgress", "FederatedPs")(stage, detail)
source(file.path(config$project, "windows", "common.R"))
source(file.path(config$project, "windows", "db-runtime.R"))
progress("startup", "Checking offline runtime")
fp_verify_runtime(config$project, config$configDirectory, config$dbBackend)
fp_check_names(config$runId, config$sites)
stopifnot(role %in% c("aggregator", config$sites))
Sys.setenv(PDA_DIR = config$exchange, FEDERATEDPS_SITE = role,
           FEDERATEDPS_RUN = config$runId, FEDERATEDPS_STUDY = config$study,
           FEDERATEDPS_SCENARIO = config$scenario,
           FEDERATEDPS_SITES = paste(config$sites, collapse = ","))
# Separate scratch files as well as results. No process changes the current
# directory of another process, and no clinical rows enter the exchange folder.
scratch <- file.path(out, "andromeda")
dir.create(scratch, recursive = TRUE, showWarnings = FALSE)
options(andromedaTempFolder = scratch)
pda_config <- pda::getCloudConfig(site_id = role, dir = config$exchange)
if (role == "aggregator") {
    result <- FederatedPs::aggregatePs(pda_config, config$sites, config$runId,
        timeout = config$exchangeTimeout,
        initialTimeout = fp_timeout_value(config, "initialTimeout", 21600))
} else if (config$mode %in% c("Database", "SyntheticCDM")) {
    result <- local({
        yuhs <- config$dataset == "YUHS"
        if (yuhs) fp_check_yuhs_sites(config)
        synthetic <- config$mode == "SyntheticCDM"
        data <- if (synthetic) {
            progress("sample", "Loading local synthetic CDM")
            fp_check_synthetic_yuhs(config)
            Sys.unsetenv(fp_connection_keys())
            cat("TEST=true: loading invented local CDM tables; DB access is disabled in this path.\n")
            FederatedPs::getSyntheticYuhsStudyData(config$careSites[[role]], config$study, config$scenario)
        } else {
            fp_configure_db_runtime(config, out)
            connection <- if (yuhs) fp_read_yuhs_connection(file.path(config$configDirectory, "yuhs.Renviron"), dbBackend = config$dbBackend) else
                fp_read_connection(file.path(config$configDirectory, paste0(role, ".Renviron")))
            connection <- fp_prepare_db_connection(connection, config)
            fp_get_db_study_data(connectionDetails = connection,
                cdmDatabaseSchema = Sys.getenv("CDM_DATABASE_SCHEMA"),
                study = config$study, scenario = config$scenario,
                careSiteId = if (yuhs) config$careSites[[role]] else NULL)
        }
        on.exit(Andromeda::close(data))
        if (yuhs) {
            metadata <- attr(data, "metaData")
            saveRDS(metadata, file.path(out, "extraction-metadata.rds"))
            for (name in c("careSite", "sitePartition", "recordLinkage", "attrition"))
                write.csv(metadata[[name]], file.path(out, paste0(name, ".csv")), row.names = FALSE, fileEncoding = "UTF-8")
        }
        progress("population", "Creating study population")
        population <- CohortMethod::createStudyPopulation(data,
            createStudyPopulationArgs = CohortMethod::createCreateStudyPopulationArgs(
                removeSubjectsWithPriorOutcome = FALSE, minDaysAtRisk = 0))
        if (synthetic) {
            # Only invented rows are saved for the pooled numerical reference.
            saveRDS(list(cohorts = dplyr::collect(data$cohorts),
                         covariates = dplyr::collect(data$covariates), synthetic = TRUE),
                    file.path(out, "synthetic-cdm-input.rds"))
        }
        fitted <- FederatedPs::fitPs(data, population, config = pda_config, runId = config$runId,
            priorVariance = 1, control = fp_control(config), timeout = config$exchangeTimeout,
            initialTimeout = fp_timeout_value(config, "initialTimeout", 21600))
        if (yuhs) {
            fitted <- fp_attach_person_ids(fitted, dplyr::collect(data$cohorts))
            attr(fitted, "metaData")$careSiteId <- config$careSites[[role]]
            attr(fitted, "metaData")$synthetic <- synthetic
        }
        fitted
    })
} else {
    if (config$mode == "Synthetic") {
        set.seed(20261024L + match(role, config$sites))
        x <- Matrix::Matrix(matrix(rbinom(960, 1, 0.35), nrow = 120), sparse = TRUE)
        colnames(x) <- as.character(seq_len(ncol(x)) * 1000L)
        y <- rbinom(nrow(x), 1, plogis(-0.3 + x[, 1] - 0.7 * x[, 2]))
        y[1:2] <- 0:1
        data <- list(x = x, treatment = y, rowIds = seq_len(nrow(x)))
        saveRDS(data, file.path(out, "synthetic-input.rds"))
    } else {
        data <- readRDS(file.path(config$designDirectory, paste0(role, ".rds")))
    }
    result <- FederatedPs::fitPsDesign(data$x, data$treatment, data$rowIds,
        config = pda_config, runId = config$runId, priorVariance = 1,
        control = fp_control(config), timeout = config$exchangeTimeout,
        initialTimeout = fp_timeout_value(config, "initialTimeout", 21600))
}
progress("saving", "Writing role-local result.rds")
saveRDS(result, file.path(out, "result.rds"))
progress("role-complete", "Role result saved; final cross-site verification is still required")
cat("PASS:", role, "completed\n")
