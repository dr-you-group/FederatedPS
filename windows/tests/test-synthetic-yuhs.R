# Base-R fixture/routing checks. Run from the repository root.
source("R/StudySettings.R")
source("R/CareSiteData.R")
source("R/SyntheticYuhs.R")
source("windows/common.R")
expect_error <- function(expr, pattern) {
    e <- tryCatch({force(expr); NULL}, error = identity)
    stopifnot(inherits(e, "error"), grepl(pattern, conditionMessage(e)))
}
cdm <- .readSyntheticYuhsCdm("inst/extdata/yuhs-synthetic")
set.seed(42); before <- .Random.seed
fresh <- .syntheticYuhsCdm()
stopifnot(identical(before, .Random.seed))
for (table in names(cdm)) stopifnot(isTRUE(all.equal(cdm[[table]], fresh[[table]], check.attributes = FALSE)))
config <- list(dataset = "YUHS", study = "ppi", scenario = "default",
    sites = c("severance", "gangnam", "yongin"), careSites = list(severance=1, gangnam=2, yongin=3))
fp_check_synthetic_yuhs(config)
bad <- config; bad$scenario <- "studySpecific"
expect_error(fp_check_synthetic_yuhs(bad), "default")
bad <- config; bad$careSites$yongin <- 4
expect_error(fp_check_synthetic_yuhs(bad), "CARE_SITE")
expect_error(getSyntheticYuhsStudyData(1, scenario = "studySpecific"), "only")
expect_error(.prepareSyntheticYuhsTables(cdm, 4), "1, 2 and 3")

all <- lapply(1:3, function(i) .prepareSyntheticYuhsTables(cdm, i))
ids <- unlist(lapply(all, function(x) x$cohorts$personId))
stopifnot(length(ids) == 360L, !anyDuplicated(ids), !999001 %in% ids)
for (i in 1:3) {
    x <- all[[i]]
    stopifnot(nrow(x$cohorts) == 120L, setequal(x$cohorts$treatment, 0:1),
        all(x$cohorts$daysFromObsStart >= 0), all(x$cohorts$daysToObsEnd > 0),
        !anyDuplicated(x$covariates[c("rowId", "covariateId")]), all(x$covariates$covariateValue == 1),
        all(x$covariates$rowId %in% x$cohorts$rowId), all(is.finite(x$covariates$covariateId)),
        !anyNA(x$covariateRef), isTRUE(x$metaData$synthetic),
        x$metaData$sitePartition$multisitePersonsAllCdm == 1,
        identical(x$metaData$studyDefinition, all[[1]]$metaData$studyDefinition),
        !any(x$covariateRef$conceptId %in% c(948078, 923645)))
}
# Removing duplicates, bad links and old records must leave features unchanged.
clean <- cdm
for (table in c("DRUG_EXPOSURE", "CONDITION_OCCURRENCE", "PROCEDURE_OCCURRENCE", "MEASUREMENT")) {
    x <- clean[[table]]
    v <- match(x$visit_occurrence_id, clean$VISIT_OCCURRENCE$visit_occurrence_id)
    good <- !is.na(v) & x$person_id == clean$VISIT_OCCURRENCE$person_id[v]
    date <- grep("(_start_date|procedure_date|measurement_date)$", names(x), value=TRUE)[1]
    clean[[table]] <- unique(x[which(good & x[[date]] >= as.Date("2025-01-01")), ])
}
for (i in 1:3) stopifnot(identical(.prepareSyntheticYuhsTables(clean,i)$covariates, all[[i]]$covariates))
stopifnot(all(all[[1]]$metaData$recordLinkage$excludedRecords == 3L))
# Add a fourth-site visit: that person must now disappear from site 1 as well.
bad <- cdm; visit <- bad$VISIT_OCCURRENCE[1, ]; visit$care_site_id <- 4L; visit$visit_occurrence_id <- 555000L
bad$VISIT_OCCURRENCE <- rbind(bad$VISIT_OCCURRENCE, visit)
x <- .prepareSyntheticYuhsTables(bad, 1)
stopifnot(nrow(x$cohorts) == 119L, !visit$person_id %in% x$cohorts$personId)
# No future database helper may silently enter the sample loader/preparer.
for (f in c("getSyntheticYuhsStudyData", ".prepareSyntheticYuhsTables", ".readSyntheticYuhsCdm"))
    stopifnot(!any(grepl("DatabaseConnector|readRenviron|download.file|url\\(", deparse(body(get(f))))))
cat("PASS: 10 reproducible sample tables, 360 disjoint persons, binary features, invalid links, multisite exclusion and test settings\n")
