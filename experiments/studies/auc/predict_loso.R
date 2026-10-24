## Out-of-sample check of simple rules for predicting the AUC gain from federation.
## Predictors a site can compute before joining:
##   leff  = log effective sample size
##   local = own OOF AUC
##   head  = AUC of the partner model on own data minus local
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
suppressPackageStartupMessages(library(stats))
S <- FP_OUT
SUF <- if (length(commandArgs(TRUE))) commandArgs(TRUE)[1] else ""   # "" or "_cv"
fs <- list.files(file.path(S, paste0("sweep", SUF)), pattern = "_[0-9]+\\.csv$", full.names = TRUE)
sw <- do.call(rbind, lapply(fs, read.csv))
w  <- reshape(sw[, c("study","size","rep","model","eff","auc")], idvar = c("study","size","rep","eff"),
              timevar = "model", direction = "wide")
names(w) <- sub("^auc\\.", "", names(w))
w <- w[complete.cases(w[, c("local","partner","shared")]), ]
w$gain <- w$shared - w$local
w$leff <- log(w$eff)
w$head <- w$partner - w$local
cat(sprintf("sweep: %d replicates, %d studies\n", nrow(w), length(unique(w$study))))

rules <- list(
  R0_mean      = gain ~ 1,
  R1_leff      = gain ~ leff,
  R2_leff_loc  = gain ~ leff + local,
  R3_head      = gain ~ head,
  R4_head_leff = gain ~ head + leff,
  R5_all       = gain ~ head + leff + local)

## leave-one-study-out
st <- unique(w$study); P <- matrix(NA, nrow(w), length(rules), dimnames = list(NULL, names(rules)))
for (s in st) { tr <- w$study != s; te <- !tr
  for (r in names(rules)) P[te, r] <- predict(lm(rules[[r]], data = w[tr, ]), newdata = w[te, ]) }
## R3raw: gain = max(0, head), no fitting
P <- cbind(P, R3raw_maxhead = pmax(0, w$head))

TH <- 0.02  # decision threshold on the gain
ev <- function(y, p) c(RMSE = sqrt(mean((y - p)^2)), MAE = mean(abs(y - p)),
  R2oos = 1 - sum((y - p)^2) / sum((y - mean(y))^2),
  Spearman = cor(y, p, method = "spearman"),
  Acc = mean((y >= TH) == (p >= TH)))
cat("\n== sweep, leave-one-study-out, per replicate ==\n")
print(round(t(apply(P, 2, function(p) ev(w$gain, p))), 3))

## same, averaged per cell
agg <- aggregate(cbind(gain, P) ~ study + size, data = cbind(w, P), FUN = mean)
cat("\n== sweep, leave-one-study-out, per cell ==\n")
print(round(t(sapply(colnames(P), function(r) ev(agg$gain, agg[[r]]))), 3))

## rules fitted on the whole sweep, applied unchanged to the other settings
fit <- lapply(rules, lm, data = w)
ext <- function(d, label) {
  d$gain <- d$shared - d$local; d$head <- d$others - d$local
  ok <- complete.cases(d[, c("gain","head","local","leff")]); d <- d[ok, ]
  Q <- sapply(names(rules), function(r) predict(fit[[r]], newdata = d))
  Q <- cbind(Q, R3raw_maxhead = pmax(0, d$head))
  cat(sprintf("\n== %s (%d replicates, gain < 0 in %.0f%%) ==\n", label, nrow(d), 100*mean(d$gain < 0)))
  print(round(t(apply(Q, 2, function(p) c(ev(d$gain, p),
    HarmCaught = if (any(d$gain < 0)) mean(p[d$gain < 0] < 0) else NA))), 3))
  invisible(cbind(d, Q))
}
## consortium sites have n = 1000; effective sample size from the cohort prevalence
effOf <- function(study, src) {
  f <- sprintf("%s/design/%s__%s.rds", S, study, ifelse(src == "mimic", "mimiciv", "mimiciv"))
  dd <- readRDS(f); p <- mean(dd$treatment); 4 * 1000 * p * (1 - p) }
co <- do.call(rbind, lapply(list.files(file.path(S, paste0("consortium", SUF)), pattern = "_n[0-9]+_[a-z]+\\.csv$", full.names = TRUE), read.csv))
cw <- reshape(co, idvar = c("study","K","n","src","rep"), timevar = "model", direction = "wide")
names(cw) <- sub("^auc\\.", "", names(cw))
pe <- sapply(unique(cw$study), function(s) effOf(s, "mimic"))
cw$leff <- log(pe[cw$study])
cc <- ext(cw[cw$src == "mimic", ], "consortium, MIMIC partners")
cm <- ext(cw[cw$src == "mixed", ], "consortium, SynPUF partners")
## heterogeneous partners
he <- do.call(rbind, lapply(list.files(file.path(S, paste0("hetero", SUF)), pattern = "__(hetero|homo)\\.csv$", full.names = TRUE), read.csv))
he$leff <- log(pe[he$study])
hh <- ext(he[he$mode == "hetero", ], "other-cluster partners")
saveRDS(list(sweep = cbind(w, P), cons_mimic = cc, cons_mixed = cm, hetero = hh, fit = fit),
        file.path(S, "predict", paste0("loso", SUF, ".rds")))
cat("\ncoefficients, fitted on the whole sweep:\n"); for (r in names(fit)) { cat(r, ": "); print(round(coef(fit[[r]]), 4)) }
