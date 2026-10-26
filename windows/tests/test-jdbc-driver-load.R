args <- commandArgs(TRUE)
source("windows/common.R")
source("windows/jdbc-driver.R")
selected <- normalizePath(args[1],winslash="/",mustWork=TRUE)
other <- normalizePath(args[2],winslash="/",mustWork=TRUE)
config <- tempfile(fileext=".Renviron")
writeLines(c('DBMS="sql server"','DB_SERVER=localhost','DB_PORT=1433',
    'DB_DATABASE=fixture','CDM_DATABASE_SCHEMA=fixture.CDM','DB_USER=fixture','DB_PASSWORD=fixture',
    'DB_ENCRYPT=false','DB_TRUST_SERVER_CERTIFICATE=false',paste0('DB_JDBC_JAR="',selected,'"')),config)
fp_configure_jdbc(normalizePath("."),config)
stopifnot(identical(getOption("FederatedPs.jdbcDriverInfo")$jar,selected),
          identical(fp_yuhs_driver_path(config),dirname(selected)))
# DatabaseConnector adds all JARs in pathToDriver. The preloaded class stays on
# the explicit selection even when the other version is subsequently added.
rJava::.jaddClassPath(other)
stopifnot(identical(fp_load_jdbc_driver(normalizePath("."),connectionFile=config)$jar,selected))
writeLines(paste0('DB_JDBC_JAR="',other,'"'),config)
stopifnot(inherits(try(fp_yuhs_driver_path(config),silent=TRUE),"try-error"),
    inherits(try(fp_load_jdbc_driver(normalizePath("."),connectionFile=config),silent=TRUE),"try-error"))
unlink(config)
cat("PASS: Renviron-selected real driver origin; adding another JAR does not change selection; restart needed for changed setting\n")
