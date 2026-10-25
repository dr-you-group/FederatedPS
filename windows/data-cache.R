# Completed extraction checkpoints only. Never serialize an open Andromeda/JDBC
# handle. Model method, block size, alpha and output/run IDs are not cache keys.
fp_object_md5 <- function(value) {
    path <- tempfile(); on.exit(unlink(path))
    saveRDS(value, path, version = 2, compress = FALSE)
    unname(tools::md5sum(path))
}

fp_data_contract <- function(config, runtimeVersions = NULL) {
    if (is.null(runtimeVersions)) runtimeVersions <- vapply(
        c("FederatedPs", "CohortMethod", "Andromeda", "DatabaseConnector"),
        function(p) as.character(utils::packageVersion(p)), "")
    project <- config$project
    files <- c("DESCRIPTION", "windows/common.R", "windows/db-runtime.R",
        "windows/run-baselines.R", "windows/baseline-models.R", "windows/data-cache.R",
        paste0("R/", list.files(file.path(project,"R"), pattern="[.]R$", full.names=FALSE)))
    # Explicit relative paths keep keys independent of a bundle's disk location.
    files <- c(files, paste0("inst/sql/sql_server/", list.files(file.path(project,"inst/sql/sql_server"))))
    if (isTRUE(config$test)) files <- c(files, paste0("inst/extdata/yuhs-synthetic/",
        list.files(file.path(project,"inst/extdata/yuhs-synthetic"))))
    files <- sort(unique(files))
    hashes <- tools::md5sum(file.path(project, files))
    if (anyNA(hashes)) stop("Cannot fingerprint extraction sources")
    names(hashes) <- files
    connectionHash <- if (isTRUE(config$test)) "synthetic-no-database" else
        unname(tools::md5sum(file.path(config$configDirectory,"yuhs.Renviron")))
    if (anyNA(connectionHash)) stop("Cannot fingerprint database settings")
    list(format=1L, test=isTRUE(config$test), study=config$study, scenario=config$scenario,
        sites=config$sites, careSites=config$careSites, patientLimit=as.integer(config$patientLimit),
        connectionHash=connectionHash, sources=hashes, runtime=runtimeVersions)
}

fp_cached_design_valid <- function(design, site, limit) {
    if (!identical(design$site, site) || !inherits(design$x, "sparseMatrix") ||
        nrow(design$x) != nrow(design$population) || !nrow(design$x) ||
        !all(c("rowId","personId","treatment","site") %in% names(design$population)) ||
        anyDuplicated(design$population$personId) || anyNA(design$population$personId) ||
        !identical(rownames(design$x), paste(site,design$population$rowId,sep=":")) ||
        !setequal(design$population$treatment,0:1) ||
        (limit > 0L && nrow(design$x) > limit)) stop("Invalid completed extraction cache")
    invisible(TRUE)
}

fp_cache_read <- function(directory, contract, site) {
    parent <- file.path(directory, fp_object_md5(contract), site)
    if (!dir.exists(parent)) return(NULL)
    entries <- list.files(parent, pattern="[.]ready$", full.names=TRUE)
    if (!length(entries)) return(NULL)
    entry <- entries[order(file.info(entries)$mtime, decreasing=TRUE)][1]
    tryCatch({
        receipt <- readRDS(file.path(entry,"complete.rds"))
        path <- file.path(entry,"design.rds")
        if (!identical(receipt$contract, contract) || !identical(receipt$site,site) ||
            !identical(receipt$md5,unname(tools::md5sum(path)))) stop("Cache checksum/contract mismatch")
        design <- readRDS(path)
        fp_cached_design_valid(design,site,contract$patientLimit)
        list(design=design,path=entry)
    }, error=function(e) stop("Completed cache cannot be reused: ",conditionMessage(e),
        ". Run with -RebuildData to extract afresh. Cache: ",entry))
}

fp_cache_write <- function(directory, contract, site, design) {
    fp_cached_design_valid(design,site,contract$patientLimit)
    parent <- file.path(directory,fp_object_md5(contract),site)
    dir.create(parent, recursive=TRUE, showWarnings=FALSE)
    partial <- tempfile("entry-",tmpdir=parent,fileext=".partial")
    if (!dir.create(partial)) stop("Cannot create extraction checkpoint")
    path <- file.path(partial,"design.rds")
    saveRDS(design,path,compress=FALSE)
    checksum <- unname(tools::md5sum(path))
    if (is.na(checksum)) stop("Cannot checksum extraction checkpoint")
    saveRDS(list(contract=contract,site=site,md5=checksum,completedAt=Sys.time()),file.path(partial,"complete.rds"))
    ready <- sub("[.]partial$",".ready",partial)
    if (!file.rename(partial,ready)) stop("Cannot finalize extraction checkpoint")
    ready
}

fp_limit_synthetic_population <- function(population, limit) {
    if (limit == 0L || nrow(population) <= limit) return(population)
    # Deterministic interleaving of the two arms, not a random study sample.
    order <- order(as.character(population$personId))
    rank <- integer(nrow(population))
    for (arm in 0:1) { rows <- order[population$treatment[order] == arm]; rank[rows] <- seq_along(rows) }
    selected <- order(rank, -population$treatment, as.character(population$personId))[seq_len(limit)]
    population[selected,,drop=FALSE]
}
