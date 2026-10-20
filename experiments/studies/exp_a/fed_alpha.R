## Damping alpha per study: 0.4 times the ESO bound.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
suppressPackageStartupMessages(library(Matrix))
P <- 50L
cat("study,alpha,omega,d,esoAlpha\n")
for (s in commandArgs(TRUE)) {
  d0 <- sprintf(file.path(FP_OUT, "sitedata/fed_%s_f1"), s)
  om <- 0L; feats <- c()
  for (k in c("synpufA","mimic","synpufB")) {
    D <- readRDS(file.path(d0, paste0(k, ".rds")))
    om <- max(om, max(rowSums(D$x != 0)) + 1L); feats <- c(feats, as.numeric(colnames(D$x)))
  }
  dd <- length(unique(feats)) + 1L
  eso <- 1/(1 + (P-1)*(om-1)/(dd-1))
  cat(sprintf("%s,%.4f,%d,%d,%.4f\n", s, 0.4*eso, om, dd, eso))
}
