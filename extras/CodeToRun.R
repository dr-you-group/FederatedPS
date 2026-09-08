library(FederatedPs)

source("extras/ConnectionDetails.R")
config <- pda::getCloudConfig(site_id = site)

# This is a first-recorded-use methods cohort, not a confirmed new-user study.
# Calendar-year features are omitted because MIMIC dates are shifted.
covariateSettings <- FeatureExtraction::createCovariateSettings(
    useDemographicsGender = TRUE, useDemographicsAgeGroup = TRUE,
    useConditionOccurrenceLongTerm = TRUE, useDrugExposureLongTerm = TRUE,
    useProcedureOccurrenceLongTerm = TRUE, useMeasurementLongTerm = TRUE,
    longTermStartDays = -90, endDays = -1,
    excludedCovariateConceptIds = c(1545958, 1539403), addDescendantsToExclude = TRUE
)
dataArgs <- CohortMethod::createGetDbCohortMethodDataArgs(
    covariateSettings = covariateSettings, firstExposureOnly = TRUE,
    washoutPeriod = 0, minAge = 65, restrictToCommonPeriod = FALSE,
    removeDuplicateSubjects = "keep first, truncate to second"
)
population <- local({
    cohortMethodData <- CohortMethod::getDbCohortMethodData(
        connectionDetails = connectionDetails, cdmDatabaseSchema = cdmDatabaseSchema,
        # CohortMethod requires an outcome ID; -1 matches no OMOP concept.
        targetId = 1545958, comparatorId = 1539403,
        outcomeIds = -1, outcomeTable = "condition_era",
        exposureTable = "drug_era", getDbCohortMethodDataArgs = dataArgs
    )
    on.exit(Andromeda::close(cohortMethodData))
    population <- CohortMethod::createStudyPopulation(cohortMethodData,
        createStudyPopulationArgs = CohortMethod::createCreateStudyPopulationArgs(
            removeSubjectsWithPriorOutcome = FALSE, minDaysAtRisk = 0))
    fitPs(cohortMethodData, population, config = config,
        runId = Sys.getenv("FEDERATEDPS_RUN"), priorVariance = 1, timeout = 3600,
        control = Cyclops::createControl(convergenceType = "lange", seed = 1))
})
