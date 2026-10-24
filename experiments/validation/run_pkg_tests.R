source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))

suppressPackageStartupMessages({library(testthat); library(FederatedPs)})
cat("FederatedPs:", as.character(packageVersion("FederatedPs")),
    " Cyclops:", as.character(packageVersion("Cyclops")), "\n")
res <- test_dir("tests/testthat", package = "FederatedPs",
                stop_on_failure = FALSE, reporter = "summary")
df <- as.data.frame(res)
cat("\nTOTAL: failed =", sum(df$failed), " error =", sum(df$error),
    " passed =", sum(df$passed), " skipped =", sum(df$skipped), "\n")
