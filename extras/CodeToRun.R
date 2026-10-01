library(FederatedPs)

source("extras/ConnectionDetails.R")
config <- pda::getCloudConfig(site_id = site)

# Set these identically at every hospital, or use start.py's CLI options.
study <- Sys.getenv("FEDERATEDPS_STUDY", "opioid")
scenario <- Sys.getenv("FEDERATEDPS_SCENARIO", "default")
population <- local({
    cohortMethodData <- getDbStudyData(
        connectionDetails = connectionDetails, cdmDatabaseSchema = cdmDatabaseSchema,
        study = study, scenario = scenario
    )
    on.exit(Andromeda::close(cohortMethodData))
    population <- CohortMethod::createStudyPopulation(cohortMethodData,
        createStudyPopulationArgs = CohortMethod::createCreateStudyPopulationArgs(
            removeSubjectsWithPriorOutcome = FALSE, minDaysAtRisk = 0))
    fitPs(cohortMethodData, population, config = config,
        runId = Sys.getenv("FEDERATEDPS_RUN"), priorVariance = 1, timeout = 3600,
        control = Cyclops::createControl(convergenceType = "lange", seed = 1))
})
