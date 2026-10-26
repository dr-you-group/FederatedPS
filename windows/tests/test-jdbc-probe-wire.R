# Called only by test-jdbc-probe-wire.py against its loopback TDS fixture.
args <- commandArgs(trailingOnly=TRUE)
stopifnot(length(args)==4L, grepl("^[0-9]+$",args[3]))
source(file.path(args[1],"R","Progress.R"))
source(file.path(args[1],"R","DbDiagnostics.R"))
rJava::.jinit(classpath=normalizePath(args[2],mustWork=TRUE))
main <- function() {
    ds <- rJava::.jnew("com/microsoft/sqlserver/jdbc/SQLServerDataSource")
    url <- paste0("jdbc:sqlserver://127.0.0.1:",args[3],
        ";databaseName=fixture;encrypt=false;loginTimeout=3;socketTimeout=2000;queryTimeout=1;cancelQueryTimeout=1")
    rJava::.jcall(ds,"V","setURL",url)
    rJava::.jcall(ds,"V","setUser","fixture")
    rJava::.jcall(ds,"V","setPassword","fixture")
    connection <- rJava::.jcall(ds,"Ljava/sql/Connection;","getConnection")
    on.exit(try(rJava::.jcall(connection,"V","close"),silent=TRUE))
    call <- function(object,type,method,...) {
        # Control: reproduce the single removed setting against the same
        # production R implementation, same driver, and same server fixture.
        if (identical(args[4],"old") && identical(method,"executeQuery"))
            rJava::.jcall(object,"V","setMaxRows",2L)
        rJava::.jcall(object,type,method,...)
    }
    result <- .fpsJdbcSmallQuery(connection,
        "SELECT CAST(1 AS INT) AS ok, @@SPID AS session_id",
        c(ok="integer",sessionId="integer"),1,jcall=call)
    stopifnot(nrow(result)==1L,result$ok==1L,result$sessionId==70L)
    methods::setClass("WireFixtureConnection", slots=c(jConnection="ANY"))
    options(FederatedPs.clinicalNetworkTimeoutMillis=7215000L)
    .fpsSetClinicalNetworkTimeout(methods::new("WireFixtureConnection",jConnection=connection))
    stopifnot(rJava::.jcall(connection,"I","getNetworkTimeout")==7215000L)
    cat("PASS SELECT 1\n")
}
main()
