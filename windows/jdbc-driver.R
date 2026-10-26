# Resolve explicit Renviron JDBC settings before any driver class is loaded.
# Changing the classpath cannot replace a driver already loaded in the same JVM.
fp_resolve_jdbc <- function(project, connectionFile = NULL) {
    keys <- c("DB_JDBC_JAR", "DATABASECONNECTOR_JAR_FOLDER")
    inherited <- Sys.getenv(keys, unset = "")
    Sys.unsetenv(keys)
    on.exit({
        Sys.unsetenv(keys)
        present <- inherited[nzchar(inherited)]
        if (length(present)) do.call(Sys.setenv, as.list(present))
    })
    if (!is.null(connectionFile) && file.exists(connectionFile) && !readRenviron(connectionFile))
        stop("Cannot read JDBC settings from ", connectionFile)
    configured <- Sys.getenv(keys, unset = "")
    values <- if (any(nzchar(configured))) configured else inherited
    resolve <- function(path) {
        path <- path.expand(path)
        if (!grepl("^([A-Za-z]:[/\\\\]|[/\\\\])", path) && !is.null(connectionFile))
            path <- file.path(dirname(connectionFile), path)
        normalizePath(path, winslash = "/", mustWork = TRUE)
    }
    if (nzchar(values[["DB_JDBC_JAR"]])) {
        jar <- resolve(values[["DB_JDBC_JAR"]])
        if (dir.exists(jar) || !grepl("[.]jar$", jar, ignore.case=TRUE)) stop("DB_JDBC_JAR must name a JAR file")
        return(jar)
    }
    lock <- jsonlite::fromJSON(file.path(project, "windows", "runtime-lock.json"))
    folder <- values[["DATABASECONNECTOR_JAR_FOLDER"]]
    default <- Sys.getenv("FEDERATEDPS_DEFAULT_JAR_FOLDER")
    # PowerShell's default root is a fallback, not an explicit Renviron choice.
    explicit <- nzchar(configured[["DATABASECONNECTOR_JAR_FOLDER"]]) ||
        (nzchar(folder) && !identical(folder, default))
    if (!explicit && nzchar(default))
        return(resolve(file.path(default, "sqlserver", lock$sqlServerActiveDirectory, lock$sqlServerActiveJar)))
    if (!nzchar(folder)) stop("Set DATABASECONNECTOR_JAR_FOLDER or DB_JDBC_JAR in yuhs.Renviron")
    folder <- resolve(folder)
    if (!dir.exists(folder)) stop("DATABASECONNECTOR_JAR_FOLDER must be a directory; use DB_JDBC_JAR for a file")
    jars <- list.files(folder, "^(mssql-jdbc.*|sqljdbc.*)[.]jar$", full.names=TRUE, ignore.case=TRUE)
    # Preserve DatabaseConnector's conventional root/sqlserver layout as well.
    if (!length(jars)) jars <- list.files(file.path(folder,"sqlserver"),
        "^(mssql-jdbc.*|sqljdbc.*)[.]jar$", full.names=TRUE, ignore.case=TRUE)
    if (length(jars) != 1L) stop("The configured JDBC folder must contain one SQL Server JAR; set DB_JDBC_JAR to choose an exact file")
    normalizePath(jars, winslash="/", mustWork=TRUE)
}

fp_load_jdbc_driver <- function(project, connectionFile = NULL, jar = NULL) {
    if (is.null(jar)) jar <- fp_resolve_jdbc(project, connectionFile)
    jar <- normalizePath(jar, winslash="/", mustWork=TRUE)
    rJava::.jinit()
    rJava::.jaddClassPath(jar)
    driver <- rJava::.jnew("com/microsoft/sqlserver/jdbc/SQLServerDriver")
    cls <- rJava::.jcall(driver, "Ljava/lang/Class;", "getClass")
    domain <- rJava::.jcall(cls, "Ljava/security/ProtectionDomain;", "getProtectionDomain")
    source <- rJava::.jcall(domain, "Ljava/security/CodeSource;", "getCodeSource")
    location <- rJava::.jcall(source, "Ljava/net/URL;", "getLocation")
    uri <- rJava::.jcall(location, "Ljava/net/URI;", "toURI")
    file <- rJava::.jnew("java/io/File", uri)
    actual <- normalizePath(rJava::.jcall(file, "S", "getCanonicalPath"), winslash="/", mustWork=TRUE)
    same <- if (.Platform$OS.type == "windows") identical(tolower(actual),tolower(jar)) else identical(actual,jar)
    if (!same) stop("This JVM already loaded SQL Server driver ",actual,
        ". Close R/RStudio and start a new process to use ",jar)
    report <- list(jar=actual,
        version=paste(rJava::.jcall(driver,"I","getMajorVersion"),rJava::.jcall(driver,"I","getMinorVersion"),sep="."),
        java=rJava::.jcall("java/lang/System","S","getProperty","java.version"),
        rJava=as.character(utils::packageVersion("rJava")))
    options(FederatedPs.jdbcDriverInfo=report,
        FederatedPs.jdbcResolver=function(path) fp_resolve_jdbc(project,path))
    cat("JDBC ACTIVE:",actual,"; driver:",report$version,"; Java:",report$java,"; rJava:",report$rJava,"\n")
    flush(stdout())
    invisible(report)
}
