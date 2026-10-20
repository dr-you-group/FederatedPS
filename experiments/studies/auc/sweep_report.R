source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
fs <- list.files(file.path(FP_OUT, "sweep"), pattern = "^[a-z][a-z0-9_]*_[0-9]+\\.csv$", full.names = TRUE)
R <- do.call(rbind, lapply(fs, read.csv))
cat("input files:", length(fs), "\n")
R <- R[!is.na(R$auc),]
A <- aggregate(auc ~ study + size + model, R, mean)
W <- reshape(A, idvar=c("study","size"), timevar="model", direction="wide")
names(W) <- sub("^auc\\.", "", names(W))
W$gain   <- W$shared - W$local      # gain from federation
W$extra  <- W$shared - W$partner    # gain over the partner model
eff <- aggregate(eff ~ study + size, R, mean); W <- merge(W, eff)
W <- W[order(W$study, W$size),]
cat("## mean over studies, by size\n")
cat(sprintf("%8s %9s %8s %8s %8s %9s %9s %6s\n","size","effN","local","partner","shared","gain","extra","study"))
for (n in sort(unique(W$size))) { b <- W[W$size==n,]
  cat(sprintf("%8d %9.0f %8.4f %8.4f %8.4f %+9.4f %+9.4f %6d\n", n, mean(b$eff),
      mean(b$local), mean(b$partner), mean(b$shared), mean(b$gain), mean(b$extra), nrow(b))) }
cat("\n## per study: shared - local by size\n")
cat(sprintf("%-29s %7s %s\n","study","partner",paste(sprintf("%8d", sort(unique(W$size))), collapse="")))
for (s in sort(unique(W$study))) { b <- W[W$study==s,]
  cat(sprintf("%-29s %7.3f %s\n", s, b$partner[1],
      paste(sprintf("%+8.3f", b$gain[match(sort(unique(W$size)), b$size)]), collapse=""))) }
cat("\n## shared - partner\n")
cat(sprintf("%-29s %s\n","study",paste(sprintf("%8d", sort(unique(W$size))), collapse="")))
for (s in sort(unique(W$study))) { b <- W[W$study==s,]
  cat(sprintf("%-29s %s\n", s, paste(sprintf("%+8.4f", b$extra[match(sort(unique(W$size)), b$size)]), collapse=""))) }
write.csv(W, file.path(FP_OUT, "sweep/SWEEP.csv"), row.names=FALSE)
