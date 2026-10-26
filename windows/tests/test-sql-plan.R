# Uses the actual pinned SqlRender and CohortMethod SQL resources. No DB.
source("R/Progress.R")
source("R/DbDiagnostics.R")
source("R/StudySettings.R")
source("R/CareSiteData.R")
source("R/CareSiteSqlPlan.R")
source("windows/tests/fixtures/care-site-sql-reference.R")
stopifnot(as.character(utils::packageVersion("SqlRender"))=="1.19.7",
          as.character(utils::packageVersion("CohortMethod"))=="6.0.3")
events <- list()
options(FederatedPs.sqlPreparationObserver=function(x) events[[length(events)+1L]] <<- x)
count <- 0L
for (schema in c("CDM54_2601.CDM","fixture_cdm"))
for (study in listStudies()$study)
for (scenario in c("default","studySpecific"))
for (cap in c(0L,200L)) {
    settings <- getStudySettings(study,scenario)
    site <- if(cap==0L) 1L else 42L
    plan <- .fpsPrepareCareSiteSqlPlan(schema,settings,site,cap,templateRoot="inst/sql/sql_server")
    old <- suppressWarnings(referenceCareSiteSql(schema,settings,site,cap))
    stopifnot(identical(plan$batches,old),length(plan$batches[["SitePartition.sql"]]$statements)==7L,
        ("LimitPatients.sql" %in% names(plan$batches))==(cap>0L))
    count <- count+1L
}
stopifnot(count==104L,length(events)>0L,
    all(vapply(events,function(x)x$status %in% c("started","completed"),TRUE)))
options(FederatedPs.careSiteSqlPlans=list("42"=plan))
stopifnot(identical(.fpsGetCareSiteSqlPlan(schema,settings,42,200),plan))
for (request in list(list(schema,settings,1,200),list("other",settings,42,200),
                     list(schema,settings,42,300),list(schema,getStudySettings("ppi"),42,200))) {
    stopifnot(inherits(try(do.call(.fpsGetCareSiteSqlPlan,request),silent=TRUE),"try-error"))
}
options(FederatedPs.careSiteSqlPlans=NULL,FederatedPs.sqlPreparationObserver=NULL)
cat("PASS: 104 complete SQL plans exactly match the archived recipe; 13 studies, 2 scenarios, 2 schemas, caps on/off, numeric sites; setting mismatch rejected\n")
