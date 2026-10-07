site <- Sys.getenv("FEDERATEDPS_SITE")
sourceSite <- if (site %in% c("synpufA", "synpufB")) "synpuf" else site
if (!readRenviron(paste0(".Renviron.", sourceSite))) stop("Cannot read site connection settings")

connectionDetails <- DatabaseConnector::createConnectionDetails(
    dbms = "postgresql",
    server = paste(Sys.getenv("PGHOST"), Sys.getenv("PGDATABASE"), sep = "/"),
    port = as.integer(Sys.getenv("PGPORT")),
    user = Sys.getenv("PGUSER"),
    password = Sys.getenv("PGPASSWORD")
)
cdmDatabaseSchema <- Sys.getenv("CDM_DATABASE_SCHEMA")
if (site %in% c("synpufA", "synpufB")) {
    prefix <- Sys.getenv("FEDERATEDPS_PARTITION_SCHEMA", "fps_sim")
    cdmDatabaseSchema <- paste0(prefix, if (site == "synpufA") "_a" else "_b")
    if (Sys.getenv("FEDERATEDPS_PARTITION", "case") == "random") cdmDatabaseSchema <- paste0(cdmDatabaseSchema, "_random")
}
cohortDatabaseSchema <- Sys.getenv("FEDERATEDPS_COHORT_SCHEMA", paste0("fps_studies_", sourceSite))
