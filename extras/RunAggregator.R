library(FederatedPs)

config <- pda::getCloudConfig(site_id = "aggregator")
sites <- strsplit(Sys.getenv("FEDERATEDPS_SITES", "mimic,synpuf"), ",", fixed = TRUE)[[1]]
aggregatePs(config, sites = sites,
            runId = Sys.getenv("FEDERATEDPS_RUN"), timeout = 3600)
