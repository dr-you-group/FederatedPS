source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
a <- commandArgs(trailingOnly = TRUE)
site <- a[1]; dir <- a[2]; runId <- a[3]; dataRds <- a[4]
P <- as.integer(a[5]); alpha <- as.numeric(a[6]); outRds <- a[7]
tol <- if (length(a) >= 8) as.numeric(a[8]) else 1e-6

suppressPackageStartupMessages({library(Matrix); library(Cyclops)
                                library(FederatedPs)})
D <- readRDS(dataRds)
cfg <- pda::getCloudConfig(site, dir = dir)
ctl <- Cyclops::createControl(convergenceType = "lange", seed = 1L, noiseLevel = "silent",
                              tolerance = tol, maxIterations = 1000L,
                              blockSize = P, alpha = alpha)
t0 <- Sys.time()
r <- FederatedPs::fitPsDesign(x = D$x, treatment = D$treatment, rowIds = D$rowIds,
                              config = cfg, runId = runId, priorVariance = 1,
                              control = ctl, timeout = 120)
r$wall <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
r$site <- site; r$n <- length(D$rowIds); r$P <- P; r$alpha <- alpha
saveRDS(r, outRds)
cat(sprintf("[%s] done n=%d passes=%d loopRounds=%d overhead=%d wall=%.1fs\n",
            site, r$n, r$iterations, r$loopRounds, r$overheadRounds, r$wall))
