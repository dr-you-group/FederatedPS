# Local-only JSONL events; no SQL, credentials or individual records are emitted.
fp_start_progress <- function(out, role, interval = 1) {
    path <- file.path(out, "progress.jsonl")
    last <- -Inf
    lastStage <- ""
    lastDetail <- ""
    function(event) {
        now <- as.numeric(Sys.time())
        important <- event$kind != "progress" || !identical(event$stage, lastStage) ||
            isTRUE(event$completed == event$total)
        if (!important && now - last < interval) return(invisible(NULL))
        event$timestamp <- format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
        event$role <- role
        event$pid <- Sys.getpid()
        con <- file(path, open = "at", encoding = "UTF-8")
        on.exit(close(con))
        writeLines(jsonlite::toJSON(event, auto_unbox = TRUE, na = "null", null = "null"), con)
        flush(con)
        if (event$kind == "stage" &&
            (!identical(event$stage, lastStage) || !identical(event$detail, lastDetail))) {
            cat(sprintf("[%s] [%s] %s: %s\n", event$timestamp, role, event$stage, event$detail))
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
