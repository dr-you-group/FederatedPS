# Invoked only by Test-OdbcConnection.ps1 in a disposable, supervised R process.
# stdout/stderr are private and discarded by the parent; only fixed diagnostic
# labels and status fields are written to files. Never save database errors.
args <- commandArgs(TRUE)
status <- NULL
code <- tryCatch(suppressWarnings(suppressMessages({
    if(length(args)!=7L) stop("Invalid diagnostic arguments")
    project <- normalizePath(args[1],winslash="/",mustWork=TRUE)
    settings <- normalizePath(args[2],winslash="/",mustWork=TRUE)
    mode <- match.arg(args[3],c("native","production"))
    out <- normalizePath(args[4],winslash="/",mustWork=TRUE)
    token <- args[5]
    if(!grepl("^[a-f0-9]{32}$",token)) stop("Invalid diagnostic token")
    siteIds <- as.integer(strsplit(args[6],",",fixed=TRUE)[[1]])
    loginTimeout <- as.integer(args[7])
    if(is.na(loginTimeout) || loginTimeout<1L || loginTimeout>300L) stop("Invalid login timeout")
    if(!requireNamespace("jsonlite",quietly=TRUE)) stop("Missing jsonlite")
    status <- list(token=token,pid=Sys.getpid(),mode=mode,state="running",phase="Starting R probe",checks=character())
    publish <- function() {
        status$updatedUtc <<- format(Sys.time(),"%Y-%m-%dT%H:%M:%OS3Z",tz="UTC")
        # The parent tolerates an in-flight read, but requires a complete final
        # receipt after normal process exit. No connection values are written.
        jsonlite::write_json(status,file.path(out,"status.json"),auto_unbox=TRUE,pretty=TRUE)
    }
    event <- function(label,state) {
        status$phase <<- label;status$phaseState <<- state
        publish()
        line <- jsonlite::toJSON(list(utc=status$updatedUtc,mode=mode,phase=label,state=state),auto_unbox=TRUE)
        cat(line,"\n",file=file.path(out,"events.ndjson"),append=TRUE,sep="")
    }
    event("Read private connection settings","started")
    source(file.path(project,"windows","odbc-connection.R"))
    source(file.path(project,"windows","odbc-probe-checks.R"))
    values <- fp_odbc_read_settings(settings)
    event("Read private connection settings","completed")
    smallQuery <- NULL
    if(mode=="native") {
        if("rJava" %in% loadedNamespaces()) stop("Native probe loaded Java")
        connect <- function() fp_odbc_connect(values,loginTimeout=loginTimeout)
        disconnect <- DBI::dbDisconnect
    } else {
        event("Prepare SQL with production SqlRender JVM","started")
        source(file.path(project,"windows","common.R"))
        fp_verify_db_runtime_revision()
        prepared <- SqlRender::translate(SqlRender::render("SELECT 1 AS ok;"),targetDialect="sql server")
        if(!is.character(prepared) || length(prepared)!=1L || !nzchar(prepared)) stop("SQL rendering failed")
        event("Prepare SQL with production SqlRender JVM","completed")
        details <- fp_odbc_connection_details(values,loginTimeout=loginTimeout)
        connect <- function() DatabaseConnector::connect(details)
        disconnect <- DatabaseConnector::disconnect
        smallQuery <- utils::getFromNamespace(".fpsSmallSqlQuery","FederatedPs")
        options(FederatedPs.smallQueryTimeoutSeconds=loginTimeout)
        options(FederatedPs.dbStartupObserver=function(phase,ready=FALSE) event(phase,"started"))
    }
    event("ODBC connect","started")
    connection <- connect()
    event("ODBC connect","completed")
    # Failure exits the disposable process; successful completion requires an
    # explicit disconnect below. The parent also supervises R finalizers.
    status$checks <- fp_odbc_probe_checks(connection,siteIds,values$CDM_DATABASE_SCHEMA,event,smallQuery=smallQuery)
    fp_odbc_probe_disconnect(connection,event,disconnect=disconnect)
    if(mode=="native" && "rJava" %in% loadedNamespaces()) stop("Native probe loaded Java")
    status$checks <- c(status$checks,"disconnect")
    status$state <- "checks-complete"
    event("R natural exit","requested")
    0L
})),error=function(e) {
    if(!is.null(status)) {
        status$state <- "failed"
        if(exists("fp_odbc_probe_error",mode="function")) status$error <- fp_odbc_probe_error(e)
        # Never include the raw condition or connection values.
        try(publish(),silent=TRUE)
    }
    2L
})
quit(save="no",status=code,runLast=FALSE)
