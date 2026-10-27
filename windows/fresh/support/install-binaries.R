args <- commandArgs(trailingOnly=TRUE)
stopifnot(length(args)==2L, .Platform$OS.type=="windows", getRversion()=="4.6.1", .Machine$sizeof.pointer==8L)
archives <- normalizePath(args[1], winslash="/", mustWork=TRUE)
lib <- normalizePath(args[2], winslash="/", mustWork=TRUE)
.libPaths(c(lib, .libPaths()))
options(repos=NULL, install.packages.check.source="no")
lock <- read.dcf(file.path(archives,"PACKAGE_LOCK.dcf"))
stopifnot(nrow(lock)>0, !anyDuplicated(lock[,"Package"]))
for (i in seq_len(nrow(lock))) {
    package <- unname(lock[i,"Package"])
    expectedVersion <- unname(lock[i,"Version"])
    path <- file.path(archives, lock[i,"File"])
    if (!file.exists(path)) stop("Missing local Windows archive: ",path)
    installed <- installed.packages(lib.loc=lib, noCache=TRUE)
    # read.dcf() keeps a column name on a scalar, while installed.packages()
    # returns an unnamed scalar. Compare the version values, not their names.
    ready <- package %in% rownames(installed) && identical(unname(installed[package,"Version"]),expectedVersion)
    cat(sprintf("[%d/%d] %s %s: %s\n",i,nrow(lock),package,expectedVersion,if(ready) "already installed" else "installing local ZIP"))
    flush(stdout())
    if (!ready) install.packages(path, lib=lib, repos=NULL, type="win.binary", dependencies=FALSE)
    info <- installed.packages(lib.loc=lib, noCache=TRUE)
    actualVersion <- if (package %in% rownames(info)) unname(info[package,"Version"]) else NA_character_
    if (!identical(actualVersion,expectedVersion)) stop("Binary installation failed: ",package,
        "; expected=",expectedVersion,"; observed=",if (is.na(actualVersion)) "not installed" else actualVersion,
        "; library=",lib)
}
cat("PASS: all locked Windows dependency binaries installed.\n")
