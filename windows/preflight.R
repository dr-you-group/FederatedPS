args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 1L)
config <- jsonlite::fromJSON(args[1])
source(file.path(config$project, "windows", "common.R"))
fp_check_names(config$runId, config$sites)
stopifnot(config$mode %in% c("Synthetic", "SyntheticCDM", "Database", "Design"))
if (config$mode == "SyntheticCDM") fp_check_synthetic_yuhs(config)
invisible(fp_control(config)) # Fail before starting any process if the fork is incompatible.
if (config$mode == "Database") {
    FederatedPs::getStudySettings(config$study, config$scenario)
    if (config$dataset == "YUHS") {
        fp_check_yuhs_sites(config)
        invisible(fp_read_yuhs_connection(file.path(config$configDirectory, "yuhs.Renviron")))
    } else for (site in config$sites)
        invisible(fp_read_connection(file.path(config$configDirectory, paste0(site, ".Renviron"))))
}
if (config$mode == "Design") {
    for (site in config$sites) {
        data <- readRDS(file.path(config$designDirectory, paste0(site, ".rds")))
        stopifnot(all(c("x", "treatment", "rowIds") %in% names(data)),
                  nrow(data$x) == length(data$treatment), length(data$treatment) == length(data$rowIds))
    }
}
cat("Run configuration validated (no database connection opened).\n")
