args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 2L)
config <- jsonlite::fromJSON(args[1])
role <- args[2]
source(file.path(config$project, "windows", "common.R"))
fp_verify_runtime(config$project)
fp_check_names(config$runId, config$sites)
stopifnot(role %in% c("aggregator", config$sites))
out <- file.path(config$output, role)
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
                                        timeout = config$exchangeTimeout)
} else if (config$mode == "Database") {
    result <- local({
        connection <- fp_read_connection(file.path(config$configDirectory, paste0(role, ".Renviron")))
        data <- FederatedPs::getDbStudyData(connectionDetails = connection,
            cdmDatabaseSchema = Sys.getenv("CDM_DATABASE_SCHEMA"),
            study = config$study, scenario = config$scenario)
        on.exit(Andromeda::close(data))
        population <- CohortMethod::createStudyPopulation(data,
            createStudyPopulationArgs = CohortMethod::createCreateStudyPopulationArgs(
                removeSubjectsWithPriorOutcome = FALSE, minDaysAtRisk = 0))
        FederatedPs::fitPs(data, population, config = pda_config, runId = config$runId,
            priorVariance = 1, control = fp_control(config), timeout = config$exchangeTimeout)
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
        control = fp_control(config), timeout = config$exchangeTimeout)
}
saveRDS(result, file.path(out, "result.rds"))
cat("PASS:", role, "completed\n")
