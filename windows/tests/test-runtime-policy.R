# Policy regression: TLS preservation, timeout routing and no automatic retry.
source("windows/db-runtime.R")
source("windows/common.R")
stopifnot(fp_verify_db_runtime_revision("dbi-odbc-1"))
for (revision in list(NULL,"jdbc-probe-1","jdbc-probe-2","jdbc-probe-3","jdbc-probe-4","jdbc-probe-5","0.0.10"))
    stopifnot(inherits(try(fp_verify_db_runtime_revision(revision),silent=TRUE),"try-error"))
stopifnot(fp_verify_sql_plan_revision("sql-plan-4"))
for (revision in list(NULL,"sql-plan-2","sql-plan-3","0.0.10"))
    stopifnot(inherits(try(fp_verify_sql_plan_revision(revision),silent=TRUE),"try-error"))
source("R/Pda.R")
out <- tempfile();dir.create(out)
report <- fp_db_startup_reporter(list(runId="fixtureRun"),out,"17")
report("Opening JDBC database connection")
start <- jsonlite::fromJSON(file.path(out,"db-startup-start.json"))
report("Connection self-check: JDBC executeQuery")
phase <- jsonlite::fromJSON(file.path(out,"db-startup-phase.json"))
stopifnot(nzchar(phase$phaseStartedUtc))
report("Connection self-check: JDBC executeQuery")
stopifnot(identical(phase$phaseStartedUtc,
    jsonlite::fromJSON(file.path(out,"db-startup-phase.json"))$phaseStartedUtc))
stopifnot(identical(start,jsonlite::fromJSON(file.path(out,"db-startup-start.json"))),
    start$pid==Sys.getpid(),start$site=="17",!file.exists(file.path(out,"db-startup-ready.json")))
report("Connection self-check and CARE_SITE validation passed",TRUE)
ready <- jsonlite::fromJSON(file.path(out,"db-startup-ready.json"))
stopifnot(ready$state=="checks-passed",identical(ready$startedUtc,start$startedUtc))
report("Closing database connection")
stopifnot(identical(ready,jsonlite::fromJSON(file.path(out,"db-startup-ready.json"))))
sqlReport <- fp_sql_preparation_reporter(list(runId="fixtureRun"),out,"17")
sqlReport(list(id="render1",status="started",startedUtc="2026-10-26T00:00:00Z",label="Rendering"))
sqlState <- jsonlite::fromJSON(file.path(out,"sql-prepare-state.json"))
stopifnot(sqlState$runId=="fixtureRun",sqlState$pid==Sys.getpid(),sqlState$site=="17",sqlState$status=="started")
sqlReport(list(id="render1",status="completed",startedUtc="2026-10-26T00:00:00Z",label="Rendering"))
stopifnot(jsonlite::fromJSON(file.path(out,"sql-prepare-state.json"))$status=="completed")
operationReport <- fp_db_operation_reporter(list(runId="fixtureRun"),out,"17")
operationReport(list(id="query1",status="started",startedUtc="2026-10-26T00:00:00Z",label="ODBC fetch",stage="extracting"))
operationState <- jsonlite::fromJSON(file.path(out,"sql-operation-state.json"))
stopifnot(operationState$runId=="fixtureRun",operationState$pid==Sys.getpid(),
    operationState$site=="17",operationState$id=="query1",operationState$status=="started")
operationReport(list(id="query1",status="completed",startedUtc="2026-10-26T00:00:00Z",label="ODBC fetch",stage="extracting"))
stopifnot(jsonlite::fromJSON(file.path(out,"sql-operation-state.json"))$status=="completed",
    !file.exists(file.path(out,"sql-operation-state.json.partial")))
unlink(out,recursive=TRUE)
d <- list(dbms = "sql server", extraSettings =
    "databaseName=fixture;encrypt=false;trustServerCertificate=false;queryTimeout=9;socketTimeout=0;selectMethod=cursor;responseBuffering=full")
prepared <- fp_prepare_db_connection(d, list(dbQueryTimeout = 120))
stopifnot(grepl("selectMethod=direct", prepared$extraSettings, fixed=TRUE),
          grepl("responseBuffering=adaptive", prepared$extraSettings, fixed=TRUE),
          !grepl("selectMethod=cursor|responseBuffering=full",prepared$extraSettings),
          grepl("encrypt=false", prepared$extraSettings, fixed = TRUE),
          grepl("trustServerCertificate=false", prepared$extraSettings, fixed = TRUE),
          grepl("queryTimeout=120", prepared$extraSettings, fixed = TRUE),
          grepl("socketTimeout=75000", prepared$extraSettings, fixed = TRUE),
          !grepl("socketTimeout=0", prepared$extraSettings, fixed = TRUE),
          !grepl("queryTimeout=9", prepared$extraSettings, fixed = TRUE),
          identical(d$extraSettings, "databaseName=fixture;encrypt=false;trustServerCertificate=false;queryTimeout=9;socketTimeout=0;selectMethod=cursor;responseBuffering=full"))
stopifnot(fp_socket_timeout_millis(7200L) == 7215000L,
          fp_socket_timeout_millis(.Machine$integer.max) == .Machine$integer.max,
          grepl("socketTimeout=45000", fp_prepare_db_connection(d,
              list(smallQueryTimeout=30))$extraSettings, fixed=TRUE))
stopifnot(identical(fp_prepare_db_connection(list(dbms="postgresql"), list()), list(dbms="postgresql")))
for (x in list(0, -1, 1.5, NA_real_, Inf, "60", c(1, 2))) {
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
answer <- fp_get_db_study_data(.get=function(...) {calls <<- calls+1L;42})
stopifnot(answer==42, calls==1L)
calls <- 0
result <- try(fp_get_db_study_data(.get=function(...) {calls <<- calls+1L;stop(failure)}), silent=TRUE)
stopifnot(inherits(result,"try-error"), calls==1L,
          identical(attr(result,"condition"), failure))
calls <- 0
result <- try(fp_get_db_study_data(.get=function(...) {calls <<- calls+1L;stop("clinical SQL failed")}), silent=TRUE)
stopifnot(inherits(result,"try-error"), calls==1L)
cat("PASS: startup vs training timeouts, phase clocks, TLS preservation, integer bounds, first error preserved without retry\n")
