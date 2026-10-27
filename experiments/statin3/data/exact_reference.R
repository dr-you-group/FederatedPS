## Exact P = 1 reference for the statin study: pooled CCD fit over the given site designs (default
## mimic and synpuf, as used by phases/), written to $FP_DATA/statin/<site>/psModelCoef.rds for each
## site. The federated P = 1 run gives the same fit.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
SITES <- commandArgs(TRUE); if (!length(SITES)) SITES <- c("mimic", "synpuf")
D <- lapply(SITES, loadDesign)
axis <- sort(unique(unlist(lapply(D, function(d) d$feat[Matrix::colSums(d$X != 0) > 0]))))
X <- do.call(rbind, lapply(D, onAxis, axis = axis)); y <- unlist(lapply(D, `[[`, "y"))
r <- runCfg(X, y, P = 1L)
stopifnot(!r$diverged)
coef <- setNames(r$beta, c("(Intercept)", as.character(axis)))
for (s in SITES) saveRDS(coef, file.path(FP_DATA, "statin", s, "psModelCoef.rds"))
cat(sprintf("pooled %d x %d: passes %d, nonzero %d\n", nrow(X), ncol(X), r$passes, sum(coef[-1] != 0)))
