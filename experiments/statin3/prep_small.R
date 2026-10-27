## Reduced consortium: the three sites subsampled to similar sizes, stratified by treatment.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
set.seed(20260929)
TARGET <- c(mimic = 4000L, synpuf = 500L, ehrshot = NA)   # all of EHRSHOT
D <- lapply(c("synpuf","mimic","ehrshot"), loadDesign); names(D) <- c("synpuf","mimic","ehrshot")
sub <- list()
for (nm in names(D)) {
  s <- D[[nm]]; n <- nrow(s$X); tgt <- TARGET[[nm]]
  if (is.na(tgt) || tgt >= n) { keep <- seq_len(n) } else {
    t1 <- which(s$y==1); t0 <- which(s$y==0)
    n1 <- round(tgt * length(t1)/n); n0 <- tgt - n1
    keep <- sort(c(sample(t1,n1), sample(t0,n0)))
  }
  sub[[nm]] <- list(X=s$X[keep,,drop=FALSE], feat=s$feat, y=s$y[keep], rows=s$rows[keep])
}
info <- list(); allF <- c()
for (nm in names(sub)) { s <- sub[[nm]]; pres <- colSums(s$X!=0) > 0
  allF <- c(allF, s$feat[pres]); s$present <- pres; sub[[nm]] <- s
  info[[nm]] <- data.frame(site=nm, n=nrow(s$X), treated=sum(s$y==1), control=sum(s$y==0),
    prevalence=mean(s$y), features=sum(pres), omega=max(rowSums(s$X[,pres,drop=FALSE]!=0))+1L) }
axis <- sort(unique(allF)); d <- length(axis)+1L
tab <- do.call(rbind, info); tab$omega_over_d <- tab$omega/d
tot <- data.frame(site="TOTAL", n=sum(tab$n), treated=sum(tab$treated), control=sum(tab$control),
  prevalence=sum(tab$treated)/sum(tab$n), features=length(axis), omega=max(tab$omega),
  omega_over_d=max(tab$omega)/d)
print(rbind(tab, tot), row.names=FALSE, digits=4)
cat(sprintf("\nd = %d (%d covariates + intercept); pooled n = %d; p/n = %.1f\n",
            d, length(axis), sum(tab$n), d/sum(tab$n)))
cat(sprintf("size ratio %.1f : %.1f : 1\n", tab$n[2]/tab$n[3], tab$n[1]/tab$n[3]))
out <- file.path(FP_OUT, "sitedata/small"); dir.create(out, recursive=TRUE, showWarnings=FALSE)
for (nm in names(sub)) { s <- sub[[nm]]; X <- s$X[, s$present, drop=FALSE]
  colnames(X) <- as.character(s$feat[s$present])
  saveRDS(list(x=as(X,"CsparseMatrix"), treatment=s$y, rowIds=s$rows),
          file.path(out, paste0(nm,".rds"))) }
write.csv(rbind(tab,tot), file.path(FP_OUT, "statin3/tables/table12_small_sites.csv"), row.names=FALSE)
saveRDS(list(axis=axis, d=d, table=rbind(tab,tot), sites=c("synpuf","mimic","ehrshot"),
             omega_global=max(tab$omega)), file.path(FP_OUT, "statin3/meta_small.rds"))
