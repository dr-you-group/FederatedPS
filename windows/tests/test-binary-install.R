# Test the real installer loop using base-R installed.packages metadata.
# Native ZIP extraction is replaced by a fixture; Windows DLL loading is not tested.
args <- commandArgs(trailingOnly=TRUE)
stopifnot(length(args)==1L)
project <- normalizePath(args[1],mustWork=TRUE)
script <- file.path(project,"windows","fresh","support","install-binaries.R")
temp <- tempfile("fps-binary-check-")
dir.create(temp)
archives <- file.path(temp,"packages");dir.create(archives)
lib <- file.path(temp,"library");dir.create(lib)
lock <- data.frame(Package="clifixture",Version="3.6.6",File="clifixture_3.6.6.zip")
write.dcf(lock,file.path(archives,"PACKAGE_LOCK.dcf"))
invisible(file.create(file.path(archives,lock$File)))
originalPaths <- .libPaths()
originalOptions <- options()
write_fixture <- function(version) {
    path <- file.path(lib,"clifixture")
    dir.create(path,showWarnings=FALSE)
    write.dcf(data.frame(Package="clifixture",Version=version,Title="Fixture",
        Description="Fixture only.",License="MIT",Built="R 4.6.1; ; ; windows"),file.path(path,"DESCRIPTION"))
    dir.create(file.path(path,"Meta"),showWarnings=FALSE)
    saveRDS(list(DESCRIPTION=read.dcf(file.path(path,"DESCRIPTION"))[1,],
        Built=list(R=numeric_version("4.6.1"),Platform=R.version$platform,
            Date="2026-10-26",OStype="windows")),file.path(path,"Meta","package.rds"))
}
run <- function(action) {
    env <- new.env(parent=globalenv())
    env$commandArgs <- function(trailingOnly=FALSE) c(archives,lib)
    env$.Platform <- .Platform;env$.Platform$OS.type <- "windows"
    env$getRversion <- function() numeric_version("4.6.1")
    env$install.packages <- function(...) {
        calls <<- calls+1L
        action()
    }
    sys.source(script,envir=env)
}
tryCatch({
    write_fixture("3.6.6")
    ip <- installed.packages(lib.loc=lib,noCache=TRUE)
    dcf <- read.dcf(file.path(archives,"PACKAGE_LOCK.dcf"))
    stopifnot("clifixture" %in% rownames(ip),
        !identical(ip["clifixture","Version"],dcf[1,"Version"]),
        identical(unname(ip["clifixture","Version"]),unname(dcf[1,"Version"])))
    calls <- 0L
    run(function() stop("Matching version must not reinstall"))
    stopifnot(calls==0L)
    unlink(file.path(lib,"clifixture"),recursive=TRUE)
    run(function() write_fixture("3.6.6"))
    stopifnot(calls==1L)
    write_fixture("3.6.5")
    run(function() write_fixture("3.6.6"))
    stopifnot(calls==2L)
    write_fixture("3.6.5")
    message <- tryCatch({run(function() NULL);""},error=function(e) conditionMessage(e))
    stopifnot(grepl("expected=3.6.6; observed=3.6.5",message,fixed=TRUE))
    unlink(file.path(lib,"clifixture"),recursive=TRUE)
    message <- tryCatch({run(function() NULL);""},error=function(e) conditionMessage(e))
    stopifnot(grepl("observed=not installed",message,fixed=TRUE))
    cat("PASS: named DCF scalar regression, first install, resume, repair, wrong/missing version rejection.\n")
},finally={.libPaths(originalPaths);options(originalOptions);unlink(temp,recursive=TRUE)})
