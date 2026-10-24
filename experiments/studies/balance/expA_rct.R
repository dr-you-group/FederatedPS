## Balance after matching for the three large sites (SynPUF-A, MIMIC, SynPUF-B), using the saved
## out-of-fold propensity scores of analyze.R (local, pooled) and fed_collect.R (fl_real). No refitting.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
source(file.path(FP_EXP, "common/balrct.R"))
source(file.path(FP_EXP, "studies/data/sites.R"))
study <- commandArgs(TRUE)[1]

B <- buildSites(study)
saved <- readRDS(sprintf(file.path(FP_OUT, "results/%s_ps.rds"), study))
stopifnot(identical(as.numeric(unlist(saved$y)), as.numeric(unlist(B$y))))   # same sites as analyze.R
flr <- tryCatch(readRDS(sprintf(file.path(FP_OUT, "fedresults/%s_ps.rds"), study)), error = function(e) NULL)
mt <- function(ps, yy) CohortMethod::matchOnPs(data.frame(rowId = seq_along(yy), treatment = yy, propensityScore = ps),
  matchOnPsArgs = CohortMethod::createMatchOnPsArgs(caliper = 0.2, caliperScale = "standardized logit", maxRatio = 1))

out <- list()
for (k in B$nm) {
  Z <- (B$Xg[[k]][, -1, drop = FALSE] != 0) * 1; Z <- Z[, colSums(Z) > 0, drop = FALSE]
  P <- list(local = saved$ps[[k]][, "local"], pooled = saved$ps[[k]][, "pooled"])
  if (!is.null(flr)) P$fl_real <- flr[[k]]
  for (mo in names(P)) out[[length(out) + 1]] <- data.frame(study = study, site = k, model = mo, n = length(B$y[[k]]),
    t(balRCT(Z, mt(P[[mo]], B$y[[k]]))))
}
R <- do.call(rbind, out)
dir.create(file.path(FP_OUT, "smd_rct"), showWarnings = FALSE)
write.csv(R, sprintf(file.path(FP_OUT, "smd_rct/expA_%s.csv"), study), row.names = FALSE)
print(R[, c("site","model","pairs","gt01","gt01RCT","excess01","meanSMD","meanSMDRCT")], row.names = FALSE, digits = 3)
