library(FederatedPs)
baseUrl <- Sys.getenv("FEDERATEDPS_WEBAPI", "http://localhost:18080/WebAPI")
dir.create("output/studies", recursive = TRUE, showWarnings = FALSE)
publishStudyDefinitions(baseUrl, outputFile = "output/studies/atlas_ids.csv")
