# Exercise the production startup boundary without a DB or clinical extraction.
source("R/Progress.R")
source("R/DbDiagnostics.R")
source("R/CareSiteData.R")
options(FederatedPs.smallQueryTimeoutSeconds = 60, FederatedPs.progress = NULL)

metadata <- .careSiteIdMetadata(data.frame(careSiteId = 2L), 2L)
stopifnot(identical(metadata, data.frame(careSiteId = 2L, careSiteName = NA_character_,
    careSiteSourceValue = NA_character_, textMetadataFetched = FALSE)))
for (answer in list(data.frame(careSiteId = 2L), data.frame(careSiteId = 2),
    data.frame(careSiteId = integer()), data.frame(careSiteId = c(2L, 2L)),
    data.frame(careSiteId = 1L), data.frame(careSiteId = NA_integer_),
    data.frame(missingId = 2L), data.frame(careSiteIdentifier = 2L), data.frame(careSiteId = "2"),
    data.frame(careSiteId = Inf), data.frame(careSiteId = 2.5))) {
    valid <- is.numeric(answer[["careSiteId"]]) && length(answer[["careSiteId"]]) == 1L &&
        isTRUE(answer[["careSiteId"]] == 2L)
    scope <- new.env(parent = environment())
    queries <- character(); ready <- FALSE; timeoutChanged <- FALSE
    scope$.fpsDbOperation <- function(label, expr, ...) force(expr)
    scope$.fpsDiagnosticWrite <- function(...) invisible(TRUE)
    scope$.fpsSmallSqlQuery <- function(connection, sql, columns) {
        queries <<- c(queries, sql)
        if (length(queries) == 1L) {
            stopifnot(identical(columns, c(ok = "integer", sessionId = "integer")))
            return(data.frame(ok = 1L, sessionId = 70L))
        }
        stopifnot(length(queries) == 2L,
            identical(sql, "SELECT TOP (2) care_site_id FROM fixture.CDM.CARE_SITE WHERE care_site_id = 2"),
            identical(columns, c(careSiteId = "integer")))
        answer
    }
    scope$.fpsSetClinicalNetworkTimeout <- function(...) timeoutChanged <<- TRUE
    scope$.fpsDbStartupState <- function(phase, ready = FALSE) {
        if (ready) assign("ready", TRUE, envir = parent.env(scope))
    }
    boundary <- simpleError("clinical extraction boundary")
    scope$.fpsExecuteSql <- function(...) stop(boundary)
    fn <- .getCareSiteStudyData; environment(fn) <- scope
    error <- tryCatch(fn(NULL, "fixture.CDM", list(), 2L, 0L,
        list(batches = list("StudyConcepts.sql" = list(sql = "fixture", statements = "fixture")))),
        error = identity)
    stopifnot(length(queries) == 2L)
    if (valid) stopifnot(identical(error, boundary), ready, timeoutChanged)
    else stopifnot(inherits(error, "error"),
        grepl("Expected one non-NULL matching numeric CARE_SITE row", conditionMessage(error), fixed = TRUE),
        !ready, !timeoutChanged)
}
cat("PASS: production ID-only startup; reject zero/two/mismatched/NULL/missing/nonnumeric IDs before clinical work; metadata text explicitly unfetched\n")
