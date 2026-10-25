#' Aggregate plaintext Cyclops statistics
#'
#' @param config Aggregator configuration from [pda::getCloudConfig()].
#' @param sites Hospital identifiers matching their pda configurations.
#' @param runId New alphanumeric identifier shared by all hospitals.
#' @param timeout Seconds to wait for each exchange.
#' @param initialTimeout Seconds to wait during feature negotiation, including
#'   database extraction at slower sites. Defaults to `timeout`.
#' @return Invisibly returns the common named coefficient vector.
#' @details Run concurrently with one `fitPs()` call at each hospital.
#'   The aggregator receives feature definitions, model settings and statistics,
#'   never patient rows. The common Laplace prior is included only once.
#' @export
aggregatePs <- function(config, sites, runId, timeout = 300, initialTimeout = timeout) {
    .validateExchangeTimeouts(timeout, initialTimeout)
    if (length(sites) < 2L || anyDuplicated(sites) || "total" %in% sites ||
        !all(grepl("^[A-Za-z0-9]+$", c(runId, sites)))) stop("Provide distinct alphanumeric hospital identifiers")
    if (paste0(runId, "_0_total") %in% pda::pdaList(config)) stop("Use a new runId")
    round <- 0L
    # Layout state learned from the coordinate -1 specification exchange.
    blockSize <- NA_integer_
    nCoefficients <- NA_integer_
    .fpsProgress("waiting-sites", "Waiting for site extraction and feature negotiation")
    sweepProgress <- NULL
    repeat {
        key <- paste0(runId, "_", round)
        roundConfig <- config
        # Initial packets stay at the root so reused run IDs are still detected.
        if (round > 0L) {
            roundConfig$dir <- file.path(config$dir, runId, round)
            dir.create(roundConfig$dir, recursive = TRUE, showWarnings = FALSE)
        }
        replies <- list()
        wait <- if (is.na(nCoefficients)) initialTimeout else timeout
        for (site in sites) replies[[site]] <- .getPs(paste0(key, "_", site), roundConfig, wait)
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
                    stop("Hospital features, scales or fitting settings differ (including study definitions)")
                }
                references[[site]] <- values[[site]]$reference
                keep <- keep | values[[site]]$present
            }
            reference <- unique(do.call(rbind, references))
            if (anyDuplicated(reference$covariateId)) stop("Hospital feature definitions differ")
            if (!any(keep)) stop("No nonzero feature remains")
            coefficientNames <- c("(Intercept)", first$specification$features[keep])
            if (!identical(first$specification$protocol, .protocolVersion)) {
                stop("Hospital protocol version differs from the aggregator; expected ",
                     .protocolVersion)
            }
            blockSize <- .blockSizeOf(first$specification$control)
            nCoefficients <- length(coefficientNames)
            sweepProgress <- .newPsSweepProgress(nCoefficients, blockSize)
            .fpsProgress("fitting", paste("Agreed model with", nCoefficients, "coefficients"))
            result <- keep
        } else if (coordinate == -2L) {
            for (site in sites) if (!identical(values[[site]], first)) stop("Hospital final models differ")
            result <- first$coefficients
        } else {
            # Packet layout.  A coordinate packet carries w coordinates as
            #   [gradient(1..w), curvature(1..w), coefficient(1..w), bound(1..w)]
            # so the summed range is 1:(2w) and the shared range (2w+1):(4w).
            # At w == 1 these are 1:2 and 3:4, i.e. the original scalar layout.
            if (coordinate == 0L) {
                width <- 1L
                shared <- 2L
                summed <- 1L
            } else {
                width <- .packetWidth(first, coordinate, blockSize, nCoefficients)
                shared <- (2L * width + 1L):(4L * width)
                summed <- seq_len(2L * width)
            }
            result <- first
            result[summed] <- 0
            for (site in sites) {
                if (length(values[[site]]) != length(first)) {
                    stop("Hospital packet layouts differ at coordinate ", coordinate)
                }
                if (any(!is.finite(values[[site]]))) stop("Non-finite hospital statistics")
                if (any(values[[site]][shared] != first[shared])) stop("Hospital coefficient or prior states differ")
                result[summed] <- result[summed] + values[[site]][summed]
            }
        }
        .putPs(result, paste0(key, "_total"), roundConfig)
        if (coordinate >= 0L && !is.null(sweepProgress)) sweepProgress(coordinate)
        if (coordinate == -2L) .fpsProgress("model-complete", "All sites agreed on the final model")
        if (coordinate == -2L) return(invisible(stats::setNames(result, coefficientNames)))
        round <- round + 1L
    }
}

# Protocol identifier.  Hospitals and the aggregator must agree exactly; a
# mismatch means one side is running a different packet layout.
.protocolVersion <- "fedps/2-block"

.validateExchangeTimeouts <- function(timeout, initialTimeout) {
    for (x in list(timeout, initialTimeout)) {
        if (!is.numeric(x) || length(x) != 1L || is.na(x) || !is.finite(x) || x <= 0)
            stop("Exchange and initial timeouts must be positive finite seconds")
    }
}

.exchangeWaitSeconds <- function(coordinate, timeout, initialTimeout) {
    if (coordinate %in% c(-3L, -1L)) initialTimeout else timeout
}

.blockSizeOf <- function(control) {
    size <- control$blockSize
    if (is.null(size)) size <- 1L
    size <- as.integer(size)
    if (length(size) != 1L || is.na(size) || size < 1L) stop("Invalid common block size")
    size
}

# Expected number of coordinates in the packet announced by `coordinate`, given
# the agreed block size and coordinate count.  This pins down both the layout
# and the block ordering, so a scalar packet sent while the run is in block mode
# is rejected rather than silently summed as if it were a block of one.
.packetWidth <- function(statistics, coordinate, blockSize, nCoefficients) {
    if (is.na(blockSize) || is.na(nCoefficients)) {
        stop("Coordinate statistics arrived before the specification exchange")
    }
    if (coordinate < 1L || coordinate > nCoefficients) {
        stop("Coordinate ", coordinate, " is outside the agreed model")
    }
    if ((coordinate - 1L) %% blockSize != 0L) {
        stop("Coordinate ", coordinate, " does not start a block of ", blockSize)
    }
    expected <- min(blockSize, nCoefficients - coordinate + 1L)
    if (length(statistics) != 4L * expected) {
        stop("Expected a ", expected, "-coordinate packet (", 4L * expected,
             " values) at coordinate ", coordinate, " but received ",
             length(statistics))
    }
    expected
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
    nextReport <- Sys.time() + 5
    while (!paste0(name, "_ready") %in% pda::pdaList(config)) {
        if (Sys.time() >= deadline) stop("Timed out waiting for ", name)
        if (Sys.time() >= nextReport) {
            .fpsProgress("waiting-exchange", paste("Waiting for", name), kind = "wait")
            nextReport <- Sys.time() + 10
        }
        Sys.sleep(0.001)
    }
    pda::pdaGet(name, config)
}
