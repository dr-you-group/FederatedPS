## Federated runs (fl_real) next to pooled and local, per study.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
A <- read.csv(file.path(FP_OUT, "results/ALL.csv"))
fs <- grep("_rounds\\.csv$", list.files(file.path(FP_OUT, "fedresults"), pattern = "^[a-z][a-z0-9_]*\\.csv$", full.names = TRUE), invert = TRUE, value = TRUE)
fs <- grep("_rounds\\.csv$|FED_ALL\\.csv$", fs, invert=TRUE, value=TRUE)
if (!length(fs)) { cat("no federated results\n"); quit(status=0) }
F <- do.call(rbind, lapply(fs, read.csv))
R <- do.call(rbind, lapply(list.files(file.path(FP_OUT, "fedresults"), pattern="_rounds\\.csv$",
                                      full.names=TRUE), read.csv))
SITES <- c("synpufA","mimic","synpufB")
for (s in sort(unique(F$study))) {
  cat(sprintf("\n=== %s ===\n", s))
  cat(sprintf("%-8s %-8s %8s %9s %8s %6s %8s\n","site","model","pairs","meanSMD","maxSMD",">0.1","AUC"))
  for (k in SITES) {
    for (m in c("local","pooled")) { r <- A[A$study==s & A$site==k & A$model==m,]
      if (!nrow(r)) next
      cat(sprintf("%-8s %-8s %8d %9.5f %8.4f %6d %8.4f\n", k, m, r$pairs, r$meanSMD, r$maxSMD, r$nGt0.1, r$auc)) }
    r <- F[F$study==s & F$site==k,]; p <- A[A$study==s & A$site==k & A$model=="pooled",]
    if (!nrow(r)) next
    cat(sprintf("%-8s %-8s %8d %9.5f %8.4f %6d %8.4f  <- fl_real\n", k, "fl_real",
        r$pairs, r$meanSMD, r$maxSMD, r$nGt0.1, r$auc))
    cat(sprintf("%-8s %-8s %+8d %+9.5f %+8.4f %+6d %+8.4f  <- fl_real - pooled\n", "", "",
        r$pairs-p$pairs, r$meanSMD-p$meanSMD, r$maxSMD-p$maxSMD, r$nGt0.1-p$nGt0.1, r$auc-p$auc))
  }
}
cat("\n\n## fl_real - pooled AUC\n")
cat(sprintf("%-29s %10s %10s %10s %12s %9s\n","study","synpufA","MIMIC","synpufB","loopRounds","reduction"))
for (s in sort(unique(F$study))) {
  d <- sapply(SITES, function(k) {
    r <- F[F$study==s & F$site==k,]; p <- A[A$study==s & A$site==k & A$model=="pooled",]
    if (!nrow(r)||!nrow(p)) NA_real_ else r$auc - p$auc })
  rr <- R[R$study==s,]
  nco <- A$nCov[A$study==s & A$site=="synpufA" & A$model=="pooled"]
  cat(sprintf("%-29s %+10.4f %+10.4f %+10.4f %12.0f %8.1fx\n", s, d[1], d[2], d[3],
      mean(rr$loopRounds), mean(rr$passes)*(nco+1)/mean(rr$loopRounds)))
}
all <- unlist(lapply(sort(unique(F$study)), function(s) sapply(SITES, function(k) {
  r <- F[F$study==s & F$site==k,]; p <- A[A$study==s & A$site==k & A$model=="pooled",]
  if (!nrow(r)||!nrow(p)) NA_real_ else r$auc - p$auc })))
cat(sprintf("\nAUC difference: mean %+.5f, max |.| %.5f, %d cells\n",
    mean(all, na.rm=TRUE), max(abs(all), na.rm=TRUE), sum(!is.na(all))))
write.csv(F, file.path(FP_OUT, "fedresults/FED_ALL.csv"), row.names=FALSE)
