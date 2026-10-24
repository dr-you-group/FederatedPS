## Export one site's statin design (atorvastatin vs simvastatin, age >= 65, first exposure) as sparse
## triplets to $FP_DATA/statin/<site>/design.rds, and the study population to population.rds. Run from the repository root at each site with the
## site's connection settings (extras/ConnectionDetails.R, FEDERATEDPS_SITE).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source("extras/ConnectionDetails.R")
site <- Sys.getenv("FEDERATEDPS_SITE")
covariateSettings <- FeatureExtraction::createCovariateSettings(
    useDemographicsGender = TRUE, useDemographicsAgeGroup = TRUE,
    useConditionOccurrenceLongTerm = TRUE, useDrugExposureLongTerm = TRUE,
    useProcedureOccurrenceLongTerm = TRUE, useMeasurementLongTerm = TRUE,
    longTermStartDays = -90, endDays = -1,
    excludedCovariateConceptIds = c(1545958, 1539403), addDescendantsToExclude = TRUE)
dataArgs <- CohortMethod::createGetDbCohortMethodDataArgs(
    covariateSettings = covariateSettings, firstExposureOnly = TRUE,
    washoutPeriod = 0, minAge = 65, restrictToCommonPeriod = FALSE,
    removeDuplicateSubjects = "keep first, truncate to second")
cmd <- CohortMethod::getDbCohortMethodData(
    connectionDetails = connectionDetails, cdmDatabaseSchema = cdmDatabaseSchema,
    targetId = 1545958, comparatorId = 1539403, outcomeIds = -1,
    outcomeTable = "condition_era", exposureTable = "drug_era",
    getDbCohortMethodDataArgs = dataArgs)
pop <- CohortMethod::createStudyPopulation(cmd,
    createStudyPopulationArgs = CohortMethod::createCreateStudyPopulationArgs(
        removeSubjectsWithPriorOutcome = FALSE, minDaysAtRisk = 0))
cov <- dplyr::collect(dplyr::filter(cmd$covariates, .data$rowId %in% !!pop$rowId))
out <- list(site = site, rowId = pop$rowId, treatment = pop$treatment, cov = as.data.frame(cov),
            covariateIds = sort(unique(dplyr::pull(dplyr::collect(cmd$covariateRef), covariateId))))
dir.create(file.path(FP_DATA, "statin", site), recursive = TRUE, showWarnings = FALSE)
saveRDS(out, file.path(FP_DATA, "statin", site, "design.rds"), compress = FALSE)
saveRDS(pop, file.path(FP_DATA, "statin", site, "population.rds"))
cat("saved:", site, " rows =", length(out$rowId), " nnz =", nrow(out$cov), " features =", length(out$covariateIds), "\n")
Andromeda::close(cmd)
