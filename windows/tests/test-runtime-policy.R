# Base-R policy regression: TLS preservation, timeout routing and restricted retry.
source("windows/db-runtime.R")
source("R/Pda.R")
out <- tempfile();dir.create(out)
report <- fp_db_startup_reporter(list(runId="fixtureRun"),out,"17")
report("Opening JDBC database connection")
start <- jsonlite::fromJSON(file.path(out,"db-startup-start.json"))
report("Connection self-check: JDBC executeQuery")
stopifnot(identical(start,jsonlite::fromJSON(file.path(out,"db-startup-start.json"))),
    start$pid==Sys.getpid(),start$site=="17",!file.exists(file.path(out,"db-startup-ready.json")))
report("Connection self-check and CARE_SITE validation passed",TRUE)
ready <- jsonlite::fromJSON(file.path(out,"db-startup-ready.json"))
stopifnot(ready$state=="checks-passed",identical(ready$startedUtc,start$startedUtc))
report("Closing database connection")
stopifnot(identical(ready,jsonlite::fromJSON(file.path(out,"db-startup-ready.json"))))
unlink(out,recursive=TRUE)
d <- list(dbms = "sql server", extraSettings =
    "databaseName=fixture;encrypt=false;trustServerCertificate=false;queryTimeout=9")
prepared <- fp_prepare_db_connection(d, list(dbQueryTimeout = 120))
stopifnot(grepl("encrypt=false", prepared$extraSettings, fixed = TRUE),
          grepl("trustServerCertificate=false", prepared$extraSettings, fixed = TRUE),
          grepl("queryTimeout=120", prepared$extraSettings, fixed = TRUE),
          !grepl("queryTimeout=9", prepared$extraSettings, fixed = TRUE),
          identical(d$extraSettings, "databaseName=fixture;encrypt=false;trustServerCertificate=false;queryTimeout=9"))
stopifnot(identical(fp_prepare_db_connection(list(dbms="postgresql"), list()), list(dbms="postgresql")))
for (x in list(0, -1, NA_real_, Inf, "60", c(1, 2))) {
    stopifnot(inherits(try(fp_timeout_value(list(smallQueryTimeout=x), "smallQueryTimeout", 60), silent=TRUE), "try-error"))
}
stopifnot(.exchangeWaitSeconds(-3, 10, 100) == 100,
          .exchangeWaitSeconds(-1, 10, 100) == 100,
          .exchangeWaitSeconds(-2, 10, 100) == 10,
          .exchangeWaitSeconds(0, 10, 100) == 10,
          .exchangeWaitSeconds(17, 10, 100) == 10)
for (x in list(0, NA_real_, Inf, "60", c(1,2)))
    stopifnot(inherits(try(.validateExchangeTimeouts(x, 100), silent=TRUE), "try-error"))
failure <- structure(list(message="fixture initial query timeout", call=NULL),
    class=c("fps_small_query_error", "error", "condition"))
calls <- 0
answer <- fp_get_db_study_data(.get=function(...) {
    calls <<- calls+1L
    if (calls==1L) stop(failure)
    42
})
stopifnot(answer==42, calls==2L)
calls <- 0
result <- try(fp_get_db_study_data(.get=function(...) {calls <<- calls+1L;stop(failure)}), silent=TRUE)
stopifnot(inherits(result,"try-error"), calls==2L)
calls <- 0
result <- try(fp_get_db_study_data(.get=function(...) {calls <<- calls+1L;stop("clinical SQL failed")}), silent=TRUE)
stopifnot(inherits(result,"try-error"), calls==1L)
cat("PASS: startup vs training timeouts, TLS preservation, timeout validation, initial-query retry once, no clinical retry\n")
