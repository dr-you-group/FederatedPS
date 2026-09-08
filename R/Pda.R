#' Aggregate plaintext Cyclops statistics
#'
#' @param config Aggregator configuration from [pda::getCloudConfig()].
#' @param sites Hospital identifiers matching their pda configurations.
#' @param runId New alphanumeric identifier shared by all hospitals.
#' @param timeout Seconds to wait for each exchange.
#' @return Invisibly returns the common named coefficient vector.
#' @details Run concurrently with one `fitPs()` call at each hospital.
#'   The aggregator receives feature definitions, model settings and statistics,
#'   never patient rows. The common Laplace prior is included only once.
#' @export
aggregatePs <- function(config, sites, runId, timeout = 300) {
    if (length(sites) < 2L || anyDuplicated(sites) || "total" %in% sites ||
        !all(grepl("^[A-Za-z0-9]+$", c(runId, sites)))) stop("Provide distinct alphanumeric hospital identifiers")
    if (paste0(runId, "_0_total") %in% pda::pdaList(config)) stop("Use a new runId")
    round <- 0L
    repeat {
        key <- paste0(runId, "_", round)
        roundConfig <- config
        # Initial packets stay at the root so reused run IDs are still detected.
        if (round > 0L) {
            roundConfig$dir <- file.path(config$dir, runId, round)
            dir.create(roundConfig$dir, recursive = TRUE, showWarnings = FALSE)
        }
        replies <- list()
        for (site in sites) replies[[site]] <- .getPs(paste0(key, "_", site), roundConfig, timeout)
        coordinate <- replies[[1L]]$coordinate
        values <- list()
        for (site in sites) {
            if (replies[[site]]$coordinate != coordinate) stop("Hospital coordinate states differ")
            values[[site]] <- replies[[site]]$statistics
        }
        first <- values[[1L]]
        if (coordinate == -3L) {
            result <- sort(unique(unlist(values, use.names = FALSE)))
        } else if (coordinate == -1L) {
            references <- list()
            keep <- first$present
            for (site in sites) {
                if (!identical(values[[site]]$specification, first$specification)) {
                    stop("Hospital features, scales or fitting settings differ")
                }
                references[[site]] <- values[[site]]$reference
                keep <- keep | values[[site]]$present
            }
            reference <- unique(do.call(rbind, references))
            if (anyDuplicated(reference$covariateId)) stop("Hospital feature definitions differ")
            if (!any(keep)) stop("No nonzero feature remains")
            coefficientNames <- c("(Intercept)", first$specification$features[keep])
            result <- keep
        } else if (coordinate == -2L) {
            for (site in sites) if (!identical(values[[site]], first)) stop("Hospital final models differ")
            result <- first$coefficients
        } else {
            shared <- if (coordinate == 0L) 2L else 3:4
            summed <- if (coordinate == 0L) 1L else 1:2
            result <- first
            result[summed] <- 0
            for (site in sites) {
                if (any(!is.finite(values[[site]]))) stop("Non-finite hospital statistics")
                if (any(values[[site]][shared] != first[shared])) stop("Hospital coefficient or prior states differ")
                result[summed] <- result[summed] + values[[site]][summed]
            }
        }
        .putPs(result, paste0(key, "_total"), roundConfig)
        if (coordinate == -2L) return(invisible(stats::setNames(result, coefficientNames)))
        round <- round + 1L
    }
}

.putPs <- function(value, name, config) {
    # Announce only after pda has finished writing the payload. This avoids
    # reading a partially written JSON file on a shared directory.
    pda::pdaPut(value, name, config, upload_without_confirm = TRUE,
               silent_message = TRUE, digits = 17)
    pda::pdaPut(TRUE, paste0(name, "_ready"), config,
               upload_without_confirm = TRUE, silent_message = TRUE)
}

.getPs <- function(name, config, timeout) {
    deadline <- Sys.time() + timeout
    while (!paste0(name, "_ready") %in% pda::pdaList(config)) {
        if (Sys.time() >= deadline) stop("Timed out waiting for ", name)
        Sys.sleep(0.001)
    }
    pda::pdaGet(name, config)
}
