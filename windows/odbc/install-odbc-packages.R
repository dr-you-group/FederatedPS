# Install only local Windows binaries. No source compilation or online fallback.
fp_odbc_package_info <- function(package, libraries) {
    for (library in libraries) {
        path <- file.path(library, package, "DESCRIPTION")
        if (file.exists(path)) {
            metadata <- read.dcf(path)
            return(list(version = unname(metadata[1L, "Version"]), library = library))
        }
    }
    NULL
}

fp_install_odbc_packages <- function(archives, baseLibrary, overlayLibrary,
        find = fp_odbc_package_info,
        install = function(path, library) utils::install.packages(path, lib = library,
            repos = NULL, type = "win.binary", dependencies = FALSE)) {
    lock <- read.dcf(file.path(archives, "ODBC_PACKAGE_LOCK.dcf"))
    needed <- c("Package", "Version", "File", "Built")
    if (!nrow(lock) || !all(needed %in% colnames(lock)) || anyDuplicated(lock[, "Package"]))
        stop("Invalid ODBC package lock.")
    if (any(!grepl("^R 4[.]6[.]", lock[, "Built"])))
        stop("ODBC payload must contain R 4.6 Windows binaries.")
    libraries <- unique(c(overlayLibrary, baseLibrary))
    for (i in seq_len(nrow(lock))) {
        package <- unname(lock[i, "Package"])
        version <- unname(lock[i, "Version"])
        filename <- unname(lock[i, "File"])
        if (!grepl("^[A-Za-z][A-Za-z0-9.]*_[A-Za-z0-9.+-]+[.]zip$", filename))
            stop("Invalid package archive filename.")
        path <- file.path(archives, filename)
        if (!file.exists(path)) stop("Missing offline ODBC archive: ", filename)
        current <- find(package, libraries)
        ready <- !is.null(current) && utils::compareVersion(current$version, version) >= 0L
        cat(sprintf("[%d/%d] %s %s: %s\n", i, nrow(lock), package, version,
            if (ready) paste("keeping installed", current$version) else "installing local ZIP"))
        flush(stdout())
        if (!ready) {
            # Repair a stale overlay copy rather than installing a newer copy
            # below it, where R would continue loading the stale DLL/package.
            target <- if (!is.null(current) && identical(current$library, overlayLibrary))
                overlayLibrary else baseLibrary
            install(path, target)
        }
        actual <- find(package, libraries)
        if (is.null(actual) || utils::compareVersion(actual$version, version) < 0L)
            stop("ODBC package installation failed: ", package, "; required >= ", version,
                 "; observed ", if (is.null(actual)) "not installed" else actual$version)
    }
    invisible(TRUE)
}

fp_install_odbc_main <- function(args = commandArgs(trailingOnly = TRUE)) {
    if (length(args) != 3L || .Platform$OS.type != "windows" ||
        getRversion() != "4.6.1" || .Machine$sizeof.pointer != 8L)
        stop("Use the installed 64-bit R 4.6.1 runtime with archives, base and overlay paths.")
    paths <- vapply(args, normalizePath, character(1L), winslash = "/", mustWork = TRUE)
    .libPaths(c(paths[3L], paths[2L], .libPaths()))
    options(repos = NULL, install.packages.check.source = "no")
    fp_install_odbc_packages(paths[1L], paths[2L], paths[3L])
    if (!requireNamespace("odbc", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE))
        stop("Installed odbc/DBI packages could not be loaded.")
    drivers <- odbc::odbcListDrivers()
    if (!("ODBC Driver 18 for SQL Server" %in% drivers$name))
        stop("64-bit Microsoft ODBC Driver 18 for SQL Server is not registered.")
    cat("PASS: ODBC R packages load and Microsoft ODBC Driver 18 is registered.\n")
}

if (sys.nframe() == 0L) fp_install_odbc_main()
