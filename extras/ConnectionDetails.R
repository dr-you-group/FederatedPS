site <- Sys.getenv("FEDERATEDPS_SITE")
if (!readRenviron(paste0(".Renviron.", site))) stop("Cannot read site connection settings")

connectionDetails <- DatabaseConnector::createConnectionDetails(
    dbms = "postgresql",
    server = paste(Sys.getenv("PGHOST"), Sys.getenv("PGDATABASE"), sep = "/"),
    port = as.integer(Sys.getenv("PGPORT")),
    user = Sys.getenv("PGUSER"),
    password = Sys.getenv("PGPASSWORD")
)
cdmDatabaseSchema <- Sys.getenv("CDM_DATABASE_SCHEMA")
