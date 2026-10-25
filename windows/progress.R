# Local-only JSONL events; no SQL, credentials or individual records are emitted.
fp_start_progress <- function(out, role, interval = 1, historyDirectory = NULL) {
    path <- file.path(out, "progress.jsonl")
    last <- -Inf
    lastStage <- ""
    lastDetail <- ""
    history <- fp_progress_history(historyDirectory)
    function(event) {
        now <- as.numeric(Sys.time())
        important <- event$kind != "progress" || !identical(event$stage, lastStage) ||
            isTRUE(event$completed == event$total)
        if (!important && now - last < interval) return(invisible(NULL))
        event <- history(event)
        event$timestamp <- format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
        event$role <- role
        event$pid <- Sys.getpid()
        con <- file(path, open = "at", encoding = "UTF-8")
        on.exit(close(con))
        writeLines(jsonlite::toJSON(event, auto_unbox = TRUE, na = "null", null = "null"), con)
        flush(con)
        if (!is.null(event$siteId) && grepl("^[0-9]+$", event$siteId)) tryCatch({
            sites <- file.path(out, "sites")
            dir.create(sites, showWarnings = FALSE)
            jsonlite::write_json(event, file.path(sites, paste0(event$siteId, ".json")),
                auto_unbox = TRUE, na = "null", null = "null")
        }, error = function(e) NULL) # JSONL remains authoritative if a snapshot cannot be written.
        if (event$kind == "stage" &&
            (!identical(event$stage, lastStage) || !identical(event$detail, lastDetail))) {
            suffix <- ""
            op <- event$operation
            if (!is.null(op)) {
                if (!is.null(op$statementCount)) suffix <- paste0(suffix, " | SQL done ",
                    op$statementsCompleted, "/", op$statementCount, " (statement count, not row/time %)")
                if (!is.null(op$rowsAffected) && !is.na(op$rowsAffected)) suffix <- paste0(suffix, " | driver affected rows=", op$rowsAffected)
                if (!is.null(op$rowsFetched) && !is.na(op$rowsFetched)) suffix <- paste0(suffix, " | fetched rows=", op$rowsFetched)
                if (!is.null(op$sqlFile)) suffix <- paste0(suffix, " | SQL file: ", op$sqlFile)
            }
            cat(sprintf("[%s] [%s] %s: %s%s\n", event$timestamp, role, event$stage, event$detail, suffix))
            flush(stdout())
        }
        last <<- now
        if (event$kind != "wait") {
            lastStage <<- event$stage
            lastDetail <<- event$detail
        }
        invisible(NULL)
    }
}

# Estimate only an identical SQL operation in an identical local context.
# Immutable records tolerate concurrent workers and interrupted writes. A bad
# history file never changes analysis success or disables the event stream.
fp_progress_history <- function(directory) {
    active <- NULL
    warned <- FALSE
    function(event) {
        tryCatch({
            op <- event$operation
            context <- getOption("FederatedPs.progressContext")
            if (is.null(directory) || is.null(op) || is.null(op$sqlFile) || is.null(context)) return(event)
            if (op$status == "started") {
                fingerprint <- tempfile()
                on.exit(unlink(fingerprint), add = TRUE)
                saveRDS(list(format = 1L, context = context,
                    sql = unname(tools::md5sum(op$sqlFile))), fingerprint, version = 2)
                key <- unname(tools::md5sum(fingerprint))
                folder <- file.path(directory, key)
                files <- list.files(folder, pattern = "[.]rds$", full.names = TRUE)
                samples <- lapply(files, function(path) tryCatch(readRDS(path), error = function(e) NULL))
                samples <- Filter(function(x) is.list(x) && identical(x$key, key) &&
                    is.numeric(x$seconds) && length(x$seconds) == 1L && is.finite(x$seconds) &&
                    x$seconds > 0 && is.numeric(x$at) && length(x$at) == 1L && is.finite(x$at), samples)
                if (length(samples)) samples <- samples[head(order(vapply(samples, `[[`, 0, "at"), decreasing = TRUE), 5)]
                estimate <- if (length(samples)) list(seconds = median(vapply(samples, `[[`, 0, "seconds")),
                    samples = length(samples), lastCompletedUtc = format(as.POSIXct(samples[[1]]$at,
                        origin = "1970-01-01", tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")) else NULL
                active <<- list(id = op$id, key = key, folder = folder, estimate = estimate)
            }
            if (!is.null(active) && identical(active$id, op$id)) {
                event$operation$historyEstimate <- active$estimate
                if (op$status == "completed" && is.finite(op$elapsedSeconds) && op$elapsedSeconds > 0) {
                    dir.create(active$folder, recursive = TRUE, showWarnings = FALSE)
                    partial <- tempfile("sample-", tmpdir = active$folder, fileext = ".partial")
                    on.exit(unlink(partial), add = TRUE)
                    saveRDS(list(key = active$key, seconds = op$elapsedSeconds, at = as.numeric(Sys.time())), partial)
                    if (!file.rename(partial, sub("[.]partial$", ".rds", partial))) stop("Cannot finalize timing record")
                    files <- list.files(active$folder, pattern = "[.]rds$", full.names = TRUE)
                    if (length(files) > 5L) unlink(files[order(file.info(files)$mtime, decreasing = TRUE)[-(1:5)]])
                }
            }
            event
        }, error = function(e) {
            if (!warned) { message("SQL timing history unavailable; live operation logs continue."); warned <<- TRUE }
            event
        })
    }
}
