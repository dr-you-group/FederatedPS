if (.Platform$OS.type == "windows" && nzchar(Sys.getenv("FEDERATEDPS_PROJECT"))) {
    stop("This file configures legacy PostgreSQL examples. For Windows/YUHS, configure ",
         "windows/config/yuhs.Renviron and run .\\windows\\Run-YUHS.ps1 -Test $false ",
         "from the project root in a PowerShell Terminal (not the R Console).", call. = FALSE)
}
site <- Sys.getenv("FEDERATEDPS_SITE")
if (!nzchar(site)) stop("FEDERATEDPS_SITE is not set. For Windows/YUHS use windows/Run-YUHS.ps1; ",
                      "this script expects the legacy PostgreSQL site environment.", call. = FALSE)
if (!readRenviron(paste0(".Renviron.", site))) stop("Cannot read site connection settings")

connectionDetails <- DatabaseConnector::createConnectionDetails(
    dbms = "postgresql",
    server = paste(Sys.getenv("PGHOST"), Sys.getenv("PGDATABASE"), sep = "/"),
    port = as.integer(Sys.getenv("PGPORT")),
    user = Sys.getenv("PGUSER"),
    password = Sys.getenv("PGPASSWORD")
)
cdmDatabaseSchema <- Sys.getenv("CDM_DATABASE_SCHEMA")
