source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
a <- commandArgs(trailingOnly = TRUE)
dir <- a[1]; runId <- a[2]; outRds <- a[3]; sites <- a[-(1:3)]

suppressPackageStartupMessages(library(FederatedPs))
cfg <- pda::getCloudConfig("aggregator", dir = dir)
t0 <- Sys.time()
co <- FederatedPs::aggregatePs(cfg, sites, runId, timeout = 120)
wall <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
saveRDS(list(coefficients = co, wall = wall, sites = sites), outRds)
cat(sprintf("[aggregator] done, %d coefficients, wall=%.1fs\n", length(co), wall))
