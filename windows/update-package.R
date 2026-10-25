args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 2L, .Platform$OS.type == "windows", getRversion() == "4.6.1")
project <- normalizePath(args[1], winslash = "/", mustWork = TRUE)
lib <- normalizePath(args[2], winslash = "/", mustWork = TRUE)
options(repos = NULL)
status <- system2(file.path(R.home("bin"), "R.exe"), c("CMD", "INSTALL", "--no-multiarch",
    shQuote(paste0("--library=", lib)), shQuote(project)))
if (status != 0L) stop("FederatedPs update failed (", status, ")")
