args <- commandArgs(TRUE)
source("R/Progress.R")
source("R/DbDiagnostics.R")
if(args[3] == "old") source(args[5])
rJava::.jinit()
rJava::.jaddClassPath(args[2])
properties <- rJava::.jnew("java/util/Properties")
for (key in c("user","password")) rJava::.jcall(properties,"Ljava/lang/Object;","setProperty",key,"fixture")
driver <- rJava::.jnew("com/microsoft/sqlserver/jdbc/SQLServerDriver")
url <- paste0("jdbc:sqlserver://127.0.0.1:",args[1],";databaseName=fixture;encrypt=false;loginTimeout=3;socketTimeout=2000;cancelQueryTimeout=1;selectMethod=direct;responseBuffering=adaptive")
c <- rJava::.jcall(driver,"Ljava/sql/Connection;","connect",url,properties)
options(FederatedPs.sqlDiagnosticsDirectory=args[4],FederatedPs.dbStartupObserver=function(phase,ready) {cat(phase,"\n");flush(stdout())})
# Short fixture-only network deadline. The production helper asks for 16s for
# a 1s query; cap it to 2s here to test incomplete response cleanup quickly.
invoke <- function(object, type, method, ...) {
  values <- list(...)
  if(method=="setNetworkTimeout") values[[2]] <- 2000L
  do.call(rJava::.jcall,c(list(object,type,method),values))
}
result <- tryCatch(.fpsJdbcSmallQuery(c,
    "SELECT TOP (2) care_site_id, care_site_name, care_site_source_value FROM fixture.CDM.CARE_SITE WHERE care_site_id = 2",
    c(careSiteId="integer",careSiteName="character",careSiteSourceValue="character"),1L,jcall=invoke),error=identity)
if(inherits(result,"error")) {
 cat("EXPECTED_OR_TEST_FAILURE:",conditionMessage(result),"\n");flush(stdout())
 quit(save="no",status=2)
}
stopifnot(nrow(result)==as.integer(args[6]))
if(nrow(result)) stopifnot(result$careSiteId[1]==2L, result$careSiteName[1]=="Synthetic \uac15\ub0a8",is.na(result$careSiteSourceValue[1]))
# A fresh statement must still inherit adaptive buffering, so the probe cannot
# force a large subsequent query into RAM.
s <- rJava::.jcall(c,"Ljava/sql/Statement;","createStatement")
s <- rJava::.jcast(s,"com/microsoft/sqlserver/jdbc/SQLServerStatement")
stopifnot(rJava::.jcall(s,"S","getResponseBuffering")=="adaptive")
rJava::.jcall(s,"V","close")
rJava::.jcall(c,"V","close")
cat("PASS_ACTUAL_RJAVA rows=",nrow(result),"\n",sep="")
