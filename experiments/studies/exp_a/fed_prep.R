## Write per-fold training data as site files for the federated runs.
## Each site exports only its own features; the common axis is agreed in exchange -3.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "studies/data/sites.R"))
study <- commandArgs(TRUE)[1]
B <- buildSites(study)
for (f in 1:NFOLD) {
  dir <- sprintf(file.path(FP_OUT, "sitedata/fed_%s_f%d"), study, f)
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  for (k in B$nm) {
    tr <- which(B$fold[[k]] != f)
    X <- B$sites[[k]]$X[tr, , drop = FALSE]
    pres <- which(colSums(X != 0) > 0)              # drop columns that are all zero in training
    X <- X[, pres, drop = FALSE]
    colnames(X) <- as.character(B$sites[[k]]$feat[pres])
    saveRDS(list(x = as(X, "CsparseMatrix"), treatment = B$sites[[k]]$y[tr],
                 rowIds = tr), file.path(dir, paste0(k, ".rds")), compress = FALSE)
  }
  cat(sprintf("  fold %d: %s\n", f,
      paste(sapply(B$nm, function(k) sprintf("%s %d", k, sum(B$fold[[k]] != f))), collapse = " / ")))
}
