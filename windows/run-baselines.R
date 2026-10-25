args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 1L)
config <- jsonlite::fromJSON(args[1])
source(file.path(config$project, "windows", "common.R"))
source(file.path(config$project, "windows", "progress.R"))
source(file.path(config$project, "windows", "db-runtime.R"))
source(file.path(config$project, "windows", "baseline-models.R"))
source(file.path(config$project, "windows", "data-cache.R"))
context <- new.env(); context$label <- "baseline startup"
observer <- fp_start_progress(file.path(config$output, "baselines"), "baselines")
options(FederatedPs.progress = function(event) {
    event$detail <- paste0(context$label, ": ", event$detail)
    observer(event)
})
progress <- utils::getFromNamespace(".fpsProgress", "FederatedPs")

extract_site <- function(site) {
    patientLimit <- config$patientLimits[[site]]
    context$label <- paste("extract", site)
    out <- file.path(config$output, "extraction", site)
    dir.create(out, recursive = TRUE, showWarnings = FALSE)
    options(andromedaTempFolder = file.path(out, "andromeda"))
    dir.create(getOption("andromedaTempFolder"), showWarnings = FALSE)
    data <- if (isTRUE(config$test)) {
        Sys.unsetenv(fp_connection_keys())
        progress("sample", "Loading invented local CDM; no database access")
        FederatedPs::getSyntheticYuhsStudyData(config$careSites[[site]], config$study, config$scenario)
    } else {
        fp_configure_db_runtime(config, out)
        details <- fp_prepare_db_connection(fp_read_yuhs_connection(
            file.path(config$configDirectory, "yuhs.Renviron")), config)
        fp_get_db_study_data(connectionDetails = details,
            cdmDatabaseSchema = Sys.getenv("CDM_DATABASE_SCHEMA"), study = config$study,
            scenario = config$scenario, careSiteId = config$careSites[[site]], patientLimit = patientLimit)
    }
    on.exit(Andromeda::close(data))
    progress("population", "Preparing the same CohortMethod population used by the federated run")
    population <- CohortMethod::createStudyPopulation(data,
        createStudyPopulationArgs = CohortMethod::createCreateStudyPopulationArgs(
            removeSubjectsWithPriorOutcome = FALSE, minDaysAtRisk = 0))
    population <- fp_attach_person_ids(population, dplyr::collect(data$cohorts))
    if (isTRUE(config$test)) population <- fp_limit_synthetic_population(population, patientLimit)
    if (patientLimit > 0L && nrow(population) > patientLimit) stop("Patient cap exceeded")
    population$careSiteId <- config$careSites[[site]]
    attr(population, "metaData")$careSiteId <- config$careSites[[site]]
    attr(population, "metaData")$synthetic <- isTRUE(config$test)
    attr(population, "metaData")$patientLimit <- patientLimit
    metadata <- attr(data, "metaData")
    if (isTRUE(config$test)) {
        metadata$patientLimit <- as.integer(patientLimit)
        metadata$samplingPolicy <- if (patientLimit > 0L)
            "deterministic alternating synthetic treatment arms; smoke test only" else "all candidates"
    }
    saveRDS(metadata, file.path(out, "extraction-metadata.rds"))
    covariates <- dplyr::collect(dplyr::filter(data$covariates, .data$rowId %in% !!population$rowId))
    design <- fp_baseline_design(population, covariates, dplyr::collect(data$covariateRef),
        dplyr::collect(data$analysisRef), metadata, site)
    cat("EXTRACTED:", site, "subjects=", nrow(design$x), "features=", ncol(design$x), "\n")
    flush(stdout())
    design
}

main <- function() {
    fp_verify_runtime(config$project)
    fp_check_names(config$runId, config$sites)
    fp_check_yuhs_sites(config)
    stopifnot(identical(config$mode, "SelectedMethods"), identical(config$dataset, "YUHS"),
        length(config$methods) > 0L, !anyDuplicated(config$methods),
        all(config$methods %in% c("local-only", "pooled", "federated")))
    if (isTRUE(config$test)) {
        stopifnot(identical(config$study,"ppi"),identical(config$scenario,"default"),
            length(config$sites)==3L,setequal(config$sites,c("1","2","3")),
            all(vapply(config$sites,function(site) config$careSites[[site]] == as.integer(site),TRUE)))
    } else FederatedPs::getStudySettings(config$study, config$scenario)
    cat("Selected methods:", paste(config$methods, collapse = ", "), "\n")
    cat("PS are in-sample; fixed Laplace variance", config$priorVariance, "; no cross-validation.\n")
    cacheRecords <- list()
    designs <- list()
    for (site in config$sites) {
        contract <- fp_data_contract(config,site=site)
        cached <- if (isTRUE(config$rebuildData)) NULL else fp_cache_read(config$cacheDirectory,contract,site)
        if (!is.null(cached)) {
            context$label <- paste("reuse",site)
            progress("cache-hit", "Verified completed extraction; skipping DB, CohortMethod and covariate extraction")
            designs[[site]] <- cached$design
            path <- cached$path
            cat("CACHE HIT:",site,"; patients=",nrow(designs[[site]]$x),";",path,"\n")
        } else {
            designs[[site]] <- extract_site(site)
            path <- fp_cache_write(config$cacheDirectory,contract,site,designs[[site]])
            progress("checkpoint",paste(site,"complete: population and covariates saved for reuse"))
            cat("CACHE SAVED:",site,";",path,"\n")
        }
        cacheRecords[[site]] <- list(site=site,reused=!is.null(cached),path=path,patients=nrow(designs[[site]]$x))
        jsonlite::write_json(cacheRecords,file.path(config$output,"data-cache.json"),auto_unbox=TRUE,pretty=TRUE)
        flush(stdout())
        invisible(gc())
    }
    fp_baseline_validate_sites(designs)
    if ("federated" %in% config$methods) {
        dir.create(file.path(config$output, "prepared"))
        for (site in config$sites) {
            design <- designs[[site]]
            design$treatment <- design$population$treatment
            design$rowIds <- design$population$rowId
            saveRDS(design, file.path(config$output, "prepared", paste0(site, ".rds")))
        }
    }
    summaries <- list()
    if ("local-only" %in% config$methods) for (site in config$sites) {
        context$label <- paste("local-only", site)
        progress("fitting", "Starting site-only Cyclops model")
        result <- fp_baseline_fit(designs[[site]], config)
        destination <- file.path(config$output, "local", site)
        summaries[[site]] <- fp_baseline_save(result, destination, "local-only", site)
        fp_baseline_verify(designs[[site]], destination)
        cat("MODEL VERIFIED: local-only", site, "\n"); flush(stdout())
        rm(result); invisible(gc())
    }
    if ("pooled" %in% config$methods) {
        context$label <- "pooled"
        progress("model-input", "Aligning feature IDs and combining all three site designs on this server")
        pooled <- fp_baseline_pool(designs)
        progress("fitting", "Starting one centralized pooled Cyclops model")
        result <- fp_baseline_fit(pooled, config)
        destination <- file.path(config$output, "pooled")
        summaries[["pooled"]] <- fp_baseline_save(result, destination, "pooled", "all")
        fp_baseline_verify(pooled, destination)
    }
    summary <- if (length(summaries)) do.call(rbind, summaries) else data.frame()
    utils::write.csv(summary, file.path(config$output, "summary.csv"), row.names = FALSE)
    jsonlite::write_json(list(runId = config$runId, state = "results-validated",
        methods = config$methods, sites = config$sites, models = length(summaries)),
        file.path(config$output, "baselines-complete.json"), auto_unbox = TRUE, pretty = TRUE)
    progress("exiting", "Selected baseline results and prepared inputs complete; requesting R process exit")
    cat("RESULTS VERIFIED:", length(summaries), "baseline models. Process exit is still required for SUCCESS.\n")
    flush(stdout()); flush(stderr())
}
main()
quit(save = "no", status = 0L, runLast = FALSE)
