args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 3L)
project <- normalizePath(args[1], winslash = "/", mustWork = TRUE)
source_dir <- normalizePath(args[2], winslash = "/", mustWork = TRUE)
lib <- normalizePath(args[3], winslash = "/", mustWork = TRUE)
stopifnot(.Platform$OS.type == "windows", getRversion() == "4.6.1",
          .Machine$sizeof.pointer == 8L)
.libPaths(c(lib, .libPaths()))
options(repos = NULL) # No dependency resolution or downloads on the offline host.
lock <- jsonlite::fromJSON(file.path(project, "windows", "runtime-lock.json"))
description <- read.dcf(file.path(source_dir, "DESCRIPTION"))
stopifnot(description[1, "Package"] == "Cyclops")
# Record provenance even though the upstream fork retains version 3.7.1.
description <- cbind(description, RemoteSha = lock$cyclopsCommit,
                     RemoteRepo = "Cyclops", RemoteUsername = "taseong")
write.dcf(description, file.path(source_dir, "DESCRIPTION"))
for (pkg in c("Rcpp", "RcppEigen", "Andromeda", "CohortMethod", "DatabaseConnector",
              "FeatureExtraction", "Matrix", "pda", "rJava", "dplyr", "rlang", "SqlRender")) {
    if (!length(find.package(pkg, quiet = TRUE))) stop("Offline dependency missing: ", pkg)
}
r <- file.path(R.home("bin"), "R.exe")
for (source in c(source_dir, project)) {
    status <- system2(r, c("CMD", "INSTALL", "--no-multiarch",
                           shQuote(paste0("--library=", lib)), shQuote(source)))
    if (status != 0L) stop("Offline installation failed for ", source, " (", status, ")")
}
cat("Installed Cyclops and FederatedPs into", lib, "\n")
