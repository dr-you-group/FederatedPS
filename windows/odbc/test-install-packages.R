args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 1L)
source(file.path(args[1L], "windows", "odbc", "install-odbc-packages.R"))
temp <- tempfile("odbc-installer-test-")
dir.create(temp)
lock <- data.frame(Package = c("fixtureDependency", "fixtureOdbc"), Version = c("1.2.0", "2.0.0"),
    File = c("fixtureDependency_1.2.0.zip", "fixtureOdbc_2.0.0.zip"),
    Built = "R 4.6.1; x86_64-w64-mingw32; 2026-10-21; windows")
write.dcf(lock, file.path(temp, "ODBC_PACKAGE_LOCK.dcf"))
invisible(file.create(file.path(temp, lock$File)))
installed <- list()
calls <- list()
find <- function(package, libraries) installed[[package]]
install <- function(path, library) {
    i <- match(basename(path), lock$File)
    calls[[length(calls) + 1L]] <<- c(lock$Package[i], library)
    installed[[lock$Package[i]]] <<- list(version = lock$Version[i], library = library)
}
run <- function(action = install) fp_install_odbc_packages(temp, "base", "overlay", find, action)
run()
stopifnot(length(calls) == 2L, identical(calls[[1L]], c("fixtureDependency", "base")),
          identical(calls[[2L]], c("fixtureOdbc", "base")))
run(function(...) stop("Matching versions must be reused"))
installed$fixtureDependency <- list(version = "9.0.0", library = "base")
run(function(...) stop("Newer versions must not be downgraded"))
installed$fixtureOdbc <- list(version = "1.0.0", library = "overlay")
run()
stopifnot(identical(calls[[3L]], c("fixtureOdbc", "overlay")))
installed$fixtureOdbc <- list(version = "1.0.0", library = "base")
error <- tryCatch({run(function(...) NULL); ""}, error = conditionMessage)
stopifnot(grepl("installation failed: fixtureOdbc", error, fixed = TRUE))
lock$File[1L] <- "../outside.zip"
write.dcf(lock, file.path(temp, "ODBC_PACKAGE_LOCK.dcf"))
error <- tryCatch({run(); ""}, error = conditionMessage)
stopifnot(grepl("Invalid package archive filename", error, fixed = TRUE))
lock$File[1L] <- "fixtureDependency_1.2.0.zip"
lock$Built[1L] <- "R 4.5.0; x86_64-w64-mingw32; windows"
write.dcf(lock, file.path(temp, "ODBC_PACKAGE_LOCK.dcf"))
error <- tryCatch({run(); ""}, error = conditionMessage)
stopifnot(grepl("R 4.6 Windows binaries", error, fixed = TRUE))
unlink(temp, recursive = TRUE)
cat("PASS: ODBC offline installation order, reuse, newer preservation, stale-overlay repair, failed installation, path and R-series validation.\n")
