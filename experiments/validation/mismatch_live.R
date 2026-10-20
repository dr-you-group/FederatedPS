## Two site processes with different block settings: the run has to stop with an error.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))

suppressPackageStartupMessages(library(FederatedPs))
trial <- function(tag, p1, a1, p2, a2) {
  ex <- file.path(FP_EXCHANGE, paste0("mm", sample.int(1e6,1))); dir.create(ex, recursive=TRUE)
  run <- "mm"
  for (cfg in list(c("s1",p1,a1), c("s2",p2,a2)))
    system2("Rscript", c(file.path(FP_EXP, "validation/site_driver.R"), cfg[1], ex, run,
            sprintf(file.path(FP_OUT, "sitedata/b1/%s.rds"), cfg[1]), cfg[2], cfg[3],
            file.path(ex, paste0("out_", cfg[1], ".rds"))), wait=FALSE,
            stdout=file.path(ex, paste0(cfg[1],".log")), stderr=file.path(ex, paste0(cfg[1],".log")))
  cfgA <- pda::getCloudConfig("aggregator", dir = ex)
  e <- tryCatch({ aggregatePs(cfgA, c("s1","s2"), run, timeout = 25); "NO ERROR" },
                error = function(e) conditionMessage(e))
  cat(sprintf("  %-40s -> %s\n", tag, substr(e, 1, 70)))
  system(sprintf("pkill -f 'site_driver.R s[12] %s' 2>/dev/null", ex))
  Sys.sleep(1); unlink(ex, recursive=TRUE)
}
cat("live mismatch rejection (two real hospital processes):\n")
trial("same P=2 alpha=0.5 (control)",      2, 0.5, 2, 0.5)
trial("different alpha  (0.5 vs 0.6)",     2, 0.5, 2, 0.6)
trial("different blockSize (2 vs 5)",      2, 0.5, 5, 0.5)
