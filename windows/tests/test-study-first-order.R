source("R/Progress.R")
source("R/DbDiagnostics.R")
source("R/CareSiteData.R")
source("R/StudySettings.R")
options(FederatedPs.smallQueryTimeoutSeconds=NULL,FederatedPs.progress=NULL)
for (scenario in c("default","studySpecific")) for (cap in c(0L,200L)) {
    settings <- getStudySettings("ppi",scenario)
    calls <- character()
    scope <- new.env(parent=environment())
    scope$.fpsSetClinicalNetworkTimeout <- function(...)NULL
    scope$.fpsSmallSqlQuery <- function(...)data.frame(careSiteId=17L)
    scope$.fpsExecuteSql <- function(connection,sql,label,completed,statements) {
        calls <<- c(calls,label)
    }
    boundary <- simpleError("cohort-fetch boundary")
    scope$.fpsQuerySqlServer <- function(connection,sql) {
        if (identical(sql,"COHORT_BOUNDARY"))stop(boundary)
        if (grepl("study_candidates_at_site",sql,fixed=TRUE))
            return(data.frame(studyCandidatesAtSite=1000,preparedPersons=if(cap>0L&&scenario=="default")cap else 1000,linkedVisits=2000))
        if (grepl("candidate_records",sql,fixed=TRUE))return(data.frame(candidateRecords=10,excludedRecords=1))
        if (grepl("SELECT arm, ingredient_id FROM",sql,fixed=TRUE))return(data.frame(arm=c(1,0),ingredientId=c(100,200)))
        if (grepl("WHERE domain_id = 'Condition'",sql,fixed=TRUE))return(data.frame(conceptId=settings$indicationConceptIds))
        data.frame() # Neither missing-ingredient nor missing-ATC rows.
    }
    expected <- c("StudyConcepts.sql","SitePartition.sql",
        if(scenario=="default" && cap>0L)"LimitPartitionPatients.sql",
        "SiteVisits.sql","StudyDrugs.sql",if(scenario=="default")"DefaultStudy.sql" else "SpecificStudy.sql",
        if(cap>0L)"LimitPatients.sql","CohortMethod CreateOrCountCohorts.sql")
    batches <- setNames(lapply(expected,function(x)list(sql=x,statements=x)),expected)
    batches[["CohortMethod GetCohorts.sql"]]<-list(statements="COHORT_BOUNDARY")
    fn <- .getCareSiteStudyData;environment(fn)<-scope
    failure<-tryCatch(fn(NULL,"fixture.cdm",settings,17,cap,list(batches=batches)),error=identity)
    stopifnot(identical(failure,boundary),identical(calls,expected))
}
cat("PASS: production extraction order for default/specific, cap/unlimited; early cap only default; vocabulary validated before clinical extraction\n")
