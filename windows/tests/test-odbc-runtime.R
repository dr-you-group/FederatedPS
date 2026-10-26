# Dependency-free settings/routing checks. No SQL Server or JVM required.
source("windows/odbc-connection.R")
source("windows/common.R")
source("windows/db-runtime.R")
expect_error <- function(expr, pattern) {
    e <- tryCatch({force(expr); NULL}, error=identity)
    stopifnot(inherits(e,"error"), grepl(pattern,conditionMessage(e)))
    invisible(e)
}
keys <- c(fp_odbc_settings_keys(), "FEDERATEDPS_DB_BACKEND", "FEDERATEDPS_PROJECT")
saved <- Sys.getenv(keys,unset=NA_character_)
restore <- function() {
    Sys.unsetenv(keys)
    if (any(!is.na(saved))) do.call(Sys.setenv,as.list(saved[!is.na(saved)]))
}
path <- tempfile()
settings <- c('DBMS="sql server"','DB_SERVER=fixture.proxy.internal','DB_PORT=2444',
    'DB_DATABASE=CDM54_2601','DB_USER="reader;with=delimiter"',
    'DB_PASSWORD="synthetic value;= with spaces"','CDM_DATABASE_SCHEMA=CDM54_2601.CDM',
    'DB_ENCRYPT=false','DB_TRUST_SERVER_CERTIFICATE=false','DB_BACKEND=odbc')
tryCatch({
    Sys.unsetenv(keys)
    Sys.setenv(DB_PASSWORD="prior-unrelated-secret", DB_BACKEND="jdbc")
    writeLines(settings,path)
    values <- fp_odbc_read_settings(path)
    stopifnot(values$DB_PASSWORD=="synthetic value;= with spaces",
        Sys.getenv("DB_PASSWORD")=="prior-unrelated-secret",Sys.getenv("DB_BACKEND")=="jdbc")
    # Exercise the actual analysis factory route without a native driver/DB.
    runtime <- new.env(parent=globalenv())
    sys.source("windows/common.R",runtime)
    sys.source("windows/odbc-connection.R",runtime)
    runtime$fp_load_odbc_helpers <- function(...) invisible(NULL)
    runtime$fp_odbc_connection_details <- function(values,loginTimeout) list(values=values,loginTimeout=loginTimeout)
    runtime$fp_yuhs_driver_path <- function(...) stop("Unexpected JDBC path")
    built <- runtime$fp_read_yuhs_connection(path,dbBackend="odbc",loginTimeout=19)
    stopifnot(built$values$DB_SERVER=="fixture.proxy.internal",built$values$DB_PORT=="2444",
        built$values$DB_ENCRYPT=="false",built$values$DB_TRUST_SERVER_CERTIFICATE=="false",
        built$values$DB_PASSWORD==values$DB_PASSWORD,built$loginTimeout==19)
    Sys.setenv(DB_PASSWORD="prior-unrelated-secret", DB_BACKEND="jdbc")
    stopifnot(fp_resolve_db_backend(path)=="odbc",fp_resolve_db_backend(path,"jdbc")=="jdbc")
    Sys.setenv(FEDERATEDPS_DB_BACKEND="jdbc")
    stopifnot(fp_resolve_db_backend(path)=="jdbc",fp_resolve_db_backend(path,"odbc")=="odbc")
    Sys.unsetenv("FEDERATEDPS_DB_BACKEND")
    writeLines(settings[!grepl("^DB_BACKEND=",settings)],path)
    stopifnot(fp_resolve_db_backend(path)=="jdbc")
    for (x in list(NA_character_, c("jdbc","odbc"), 1L, "other"))
        expect_error(fp_resolve_db_backend(path,x), "backend")
    args <- fp_odbc_connect_args(values)
    stopifnot(identical(as.character(args$server),"{tcp:fixture.proxy.internal,2444}"),
        identical(as.character(args$uid),"{reader;with=delimiter}"),
        identical(as.character(args$pwd),"{synthetic value;= with spaces}"),
        args$Encrypt=="no",args$TrustServerCertificate=="no",args$timeout==30L,
        args$bigint=="integer64",args$APP=="FederatedPS",args$ConnectRetryCount=="0",!anyDuplicated(tolower(names(args))),
        !any(c("extraSettings","queryTimeout","socketTimeout","jdbc") %in% names(args)))
    values$DB_ENCRYPT <- "true"; values$DB_TRUST_SERVER_CERTIFICATE <- "true"
    args <- fp_odbc_connect_args(values,17)
    stopifnot(args$Encrypt=="yes",args$TrustServerCertificate=="yes",args$timeout==17L)
    values$DB_ENCRYPT <- "";values$DB_TRUST_SERVER_CERTIFICATE <- ""
    args <- fp_odbc_connect_args(values)
    stopifnot(args$Encrypt=="yes",args$TrustServerCertificate=="no")
    stopifnot(as.character(fp_odbc_quote("quoted'\";value"))=="{quoted'\";value}")
    stopifnot(fp_odbc_quote("with}brace",.quote=function(x) paste0('"',x,'"'))=='"with}brace"')
    err <- expect_error(fp_odbc_quote("private}'\"value"),"unsupported combination")
    stopifnot(!grepl("private",conditionMessage(err),fixed=TRUE))
    for (pair in list(c("DB_SERVER","jdbc:sqlserver://host"),c("DB_SERVER","host,1433"),
        c("DB_PORT","0"),c("DB_PORT","65536"),c("DB_DATABASE","db;other"),
        c("CDM_DATABASE_SCHEMA","OTHER.CDM"),c("DB_ENCRYPT","maybe"),
        c("DB_ODBC_DRIVER","SQL Server"))) {
        invalid <- values;invalid[[pair[1L]]] <- pair[2L]
        expect_error(fp_odbc_connect_args(invalid),"DB_|database|driver|port")
    }
    for (value in list(0,-1,NA_real_,Inf,1.2,"30",c(1,2)))
        expect_error(fp_odbc_connect_args(values,value),"login timeout")
    missing <- function(pkg,quietly) pkg!="odbc"
    expect_error(fp_odbc_require(values$DB_ODBC_DRIVER,.require=missing),"APPLY_ODBC")
    yes <- function(...) TRUE
    expect_error(fp_odbc_require(values$DB_ODBC_DRIVER,.require=yes,.drivers=function() data.frame(name="SQL Server")),"x64")
    fp_odbc_require(values$DB_ODBC_DRIVER,.require=yes,.drivers=function() data.frame(name=values$DB_ODBC_DRIVER))
    details <- structure(c(list(dbms="sql server"),args),class=c("ConnectionDetails","DbiConnectionDetails"))
    stopifnot(identical(fp_prepare_db_connection(details,list(dbQueryTimeout=60)),details))
    writeLines(settings[-6L],path)
    expect_error(fp_odbc_read_settings(path),"DB_PASSWORD")
    stopifnot(Sys.getenv("DB_PASSWORD")=="prior-unrelated-secret")
    fp_verify_db_runtime_revision("dbi-odbc-1")
    expect_error(fp_verify_db_runtime_revision("jdbc-probe-5"),"ODBC/JDBC")
},finally={unlink(path);restore()})
cat("PASS: ODBC backend precedence, isolated settings, endpoint/TLS mapping, quoting, dependency checks and DBI timeout routing\n")
