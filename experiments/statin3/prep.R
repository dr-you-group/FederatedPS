## Statin study on three independent sources: MIMIC-IV, SynPUF and EHRSHOT.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
SITES <- c("synpuf","mimic","ehrshot")
D <- lapply(SITES, loadDesign); names(D) <- SITES
info <- list(); allFeat <- c()
for (nm in SITES) {
  s <- D[[nm]]; pres <- colSums(s$X != 0) > 0
  allFeat <- c(allFeat, s$feat[pres])
  om <- max(rowSums(s$X[, pres, drop=FALSE] != 0)) + 1L      # +1 for the intercept
  info[[nm]] <- data.frame(site=nm, n=nrow(s$X), treated=sum(s$y==1), control=sum(s$y==0),
    prevalence=mean(s$y), features_present=sum(pres), omega_k=om,
    meanRowNnz=mean(rowSums(s$X != 0))+1)
  D[[nm]]$present <- pres
}
axis <- sort(unique(allFeat)); d <- length(axis) + 1L
tab <- do.call(rbind, info); tab$omega_over_d <- tab$omega_k/d
tot <- data.frame(site="TOTAL", n=sum(tab$n), treated=sum(tab$treated), control=sum(tab$control),
  prevalence=sum(tab$treated)/sum(tab$n), features_present=length(axis),
  omega_k=max(tab$omega_k), meanRowNnz=NA, omega_over_d=max(tab$omega_k)/d)
tab <- rbind(tab, tot)
write.csv(tab, file.path(FP_OUT, "statin3/tables/table1_sites.csv"), row.names=FALSE)
cat(sprintf("common axis: %d covariates, d = %d\n", length(axis), d))
print(tab, row.names=FALSE, digits=4)
omega_global <- max(tab$omega_k[tab$site!="TOTAL"])
eso <- function(P) 1/(1 + (P-1)*(omega_global-1)/(d-1))
cat(sprintf("\nomega_global = %d ; omega/d = %.5f ; alpha*(P=20) = %.4f\n",
            omega_global, omega_global/d, eso(20)))
cat(sprintf("site size ratio %.0f : %.0f : 1\n", tab$n[1]/tab$n[3], tab$n[2]/tab$n[3]))
out <- file.path(FP_OUT, "sitedata/tri"); dir.create(out, recursive=TRUE, showWarnings=FALSE)
for (nm in SITES) {
  s <- D[[nm]]; X <- s$X[, s$present, drop=FALSE]
  colnames(X) <- as.character(s$feat[s$present])
  saveRDS(list(x=as(X,"CsparseMatrix"), treatment=s$y, rowIds=s$rows),
          file.path(out, paste0(nm, ".rds")))
  cat(sprintf("  %-8s %7d x %6d nnz %d\n", nm, nrow(X), ncol(X), length(X@x)))
}
saveRDS(list(axis=axis, d=d, omega_global=omega_global, alphaStar=eso(20), table1=tab,
             sites=SITES), file.path(FP_OUT, "statin3/meta.rds"))
