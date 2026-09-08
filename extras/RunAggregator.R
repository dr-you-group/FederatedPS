library(FederatedPs)

config <- pda::getCloudConfig(site_id = "aggregator")
aggregatePs(config, sites = c("mimic", "synpuf"),
            runId = Sys.getenv("FEDERATEDPS_RUN"), timeout = 3600)
