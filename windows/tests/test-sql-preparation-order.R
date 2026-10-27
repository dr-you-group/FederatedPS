# Exercise the production orchestration with only external package I/O replaced.
# No DB/credentials or FederatedPs installation are needed for this boundary test.
source("R/Progress.R")
source("R/DbDiagnostics.R")
source("R/CareSiteData.R")
source("R/StudyData.R")
source("R/StudySettings.R")
source("windows/db-runtime.R")
rewrite <- function(x, names) {
    if (missing(x)) return(quote(expr=))
    if (!is.call(x)) return(x)
    if (identical(x[[1]],as.name("::")) && as.character(x[[3]]) %in% names)
        return(as.name(paste0("fixture_",as.character(x[[3]]))))
    as.call(lapply(as.list(x),rewrite,names=names))
}
scope <- new.env(parent=environment())
calls <- character()
scope$fixture_connect <- function(details) {calls <<- c(calls,"connect");"connection"}
scope$fixture_disconnect <- function(connection) {calls <<- c(calls,"disconnect")}
scope$fixture_dbms <- function(connection) "sql server"
scope$.fpsGetCareSiteSqlPlan <- function(...) {calls <<- c(calls,"prepare");list(marker=42)}
scope$.getCareSiteStudyData <- function(connection,schema,settings,careSiteId,patientLimit,sqlPlan) {
    stopifnot(sqlPlan$marker==42);calls <<- c(calls,"execute");42
}
fn <- getDbStudyData
body(fn) <- rewrite(body(fn),c("connect","disconnect","dbms"));environment(fn)<-scope
stopifnot(fn(list(dbms="sql server"),"fixture.cdm","ppi","default",17,200)==42,
    identical(calls,c("prepare","connect","execute","disconnect")))
calls<-character()
scope$.fpsGetCareSiteSqlPlan <- function(...)stop("local rendering failed")
stopifnot(inherits(try(fn(list(dbms="sql server"),"fixture.cdm","ppi","default",17,200),silent=TRUE),"try-error"),
    length(calls)==0L)
# The sequential launcher prepares ALL sites before any extraction starts.
scope$fixture_getStudySettings <- getStudySettings
scope$fp_read_connection_values <- function(...)list(CDM_DATABASE_SCHEMA="fixture.cdm")
scope$fp_configure_db_runtime <- function(config,out)NULL
fn<-fp_prepare_sql_plans
body(fn)<-rewrite(body(fn),"getStudySettings");environment(fn)<-scope
out<-tempfile();dir.create(out)
config<-list(output=out,configDirectory=out,sites=c("1","17","42"),
    study="ppi",scenario="default",careSites=list("1"=1,"17"=17,"42"=42),
    patientLimits=list("1"=200,"17"=100,"42"=300))
calls<-character()
fn(config,config$sites,prepare=function(schema,settings,id,cap) {
    calls<<-c(calls,paste(id,cap,sep=":"));list(id=id,cap=cap)
})
stopifnot(identical(calls,c("1:200","17:100","42:300")),
    identical(names(getOption("FederatedPs.careSiteSqlPlans")),config$sites))
options(FederatedPs.careSiteSqlPlans=NULL)
unlink(out,recursive=TRUE)
cat("PASS: local preparation precedes connect; preparation failure sends no DB call; all sequential site plans prepared with their own limits\n")
