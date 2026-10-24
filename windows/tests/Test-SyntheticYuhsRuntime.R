# Target-host integration test: installed packages; no database access allowed.
main <- function() {
    ns <- asNamespace("DatabaseConnector")
    guarded <- intersect(c("connect", "createConnectionDetails", "downloadJdbcDrivers"), ls(ns, all.names=TRUE))
    for (name in guarded) trace(name, where=ns,
        tracer=quote(stop("DB access is forbidden during the synthetic sample test")), print=FALSE)
    on.exit(for (name in guarded) untrace(name, where=ns), add=TRUE)
    seen <- character()
    for (id in 1:3) local({
        data <- FederatedPs::getSyntheticYuhsStudyData(id)
        on.exit(Andromeda::close(data))
        cohorts <- dplyr::collect(data$cohorts)
        population <- CohortMethod::createStudyPopulation(data,
            createStudyPopulationArgs=CohortMethod::createCreateStudyPopulationArgs(
                removeSubjectsWithPriorOutcome=FALSE, minDaysAtRisk=0))
        stopifnot(nrow(population)==120L, setequal(population$treatment,0:1),
            isTRUE(attr(data,"metaData")$synthetic), !any(cohorts$personId %in% seen),
            nrow(dplyr::collect(data$covariates)) > 0L)
        seen <<- c(seen,as.character(cohorts$personId))
    })
    cat("PASS: installed sample -> Andromeda -> CohortMethod population, 360 disjoint persons; no DB calls\n")
}
main()
