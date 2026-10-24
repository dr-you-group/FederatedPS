## Phase 6: Cox analysis after matching, with events simulated at a known hazard ratio on the
## real risk windows and covariates (the study extracts no outcomes).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
suppressPackageStartupMessages(library(survival))
set.seed(60606)
TRUE_LOG_HR <- log(1.5)

bExact <- readRDS(file.path(FP_DATA, "statin/mimic/psModelCoef.rds"))
bBlock <- readRDS(file.path(FP_OUT, "fedruns/fullP20/agg.rds"))$coefficients[names(bExact)]
axis <- as.numeric(names(bExact)[-1])
M <- loadDesign("mimic"); S <- loadDesign("synpuf")
X <- rbind(onAxis(M, axis), onAxis(S, axis)); y <- c(M$y, S$y)
popM <- readRDS(file.path(FP_DATA, "statin/mimic/population.rds")); popS <- readRDS(file.path(FP_DATA, "statin/synpuf/population.rds"))
fu <- c(popM$riskEnd[match(M$rows, popM$rowId)] - popM$riskStart[match(M$rows, popM$rowId)],
        popS$riskEnd[match(S$rows, popS$rowId)] - popS$riskStart[match(S$rows, popS$rowId)]) + 1
rm(M, S, popM, popS); invisible(gc())
cat(sprintf("pooled %d subjects; follow-up days median %.0f, max %.0f\n",
            nrow(X), median(fu), max(fu)))

## confounder: a sparse random combination of covariates that also drive treatment
w <- numeric(ncol(X)); idx <- sample(2:ncol(X), 200); w[idx] <- rnorm(200, 0, 0.35)
z <- as.vector(X %*% w); z <- (z - mean(z)) / sd(z)
lp <- TRUE_LOG_HR * y + 0.8 * z
lambda0 <- 0.004
tt <- rexp(length(y), rate = lambda0 * exp(lp))
event <- as.integer(tt <= fu); time <- pmin(tt, fu)
cat(sprintf("simulated events: %d (%.1f%%), true log HR = %.4f (HR = %.2f)\n",
            sum(event), 100*mean(event), TRUE_LOG_HR, exp(TRUE_LOG_HR)))

fitCox <- function(idx = NULL, strat = NULL, label) {
  d <- if (is.null(idx)) data.frame(time = time, event = event, tr = y)
       else data.frame(time = time[idx], event = event[idx], tr = y[idx])
  f <- if (is.null(strat)) coxph(Surv(time, event) ~ tr, data = d)
       else coxph(Surv(time, event) ~ tr + strata(strat), data = cbind(d, strat = strat))
  s <- summary(f); ci <- s$conf.int
  data.frame(analysis = label, n = nrow(d), events = sum(d$event),
             logHR = unname(coef(f)[1]), se = unname(sqrt(diag(vcov(f)))[1]),
             HR = unname(ci[1, "exp(coef)"]), lower = unname(ci[1, "lower .95"]),
             upper = unname(ci[1, "upper .95"]),
             bias_logHR = unname(coef(f)[1]) - TRUE_LOG_HR)
}
rows <- list(fitCox(NULL, NULL, "unadjusted (all subjects)"))
Z <- X[, -1, drop = FALSE]; balrows <- list()
for (nm in c("Exact federated CCD", "Proximal block CCD")) {
  b <- if (nm == "Exact federated CCD") bExact else bBlock
  ps <- 1/(1 + exp(-as.vector(X %*% unname(b))))
  pop <- data.frame(rowId = seq_along(y), treatment = y, propensityScore = ps)
  mm <- CohortMethod::matchOnPs(pop, matchOnPsArgs = CohortMethod::createMatchOnPsArgs(
          caliper = 0.2, caliperScale = "standardized logit", maxRatio = 1))
  idx <- mm$rowId
  bal <- smdStats(Z, y, idx)
  balrows[[nm]] <- data.frame(method = nm, matchedPairs = sum(mm$treatment == 1),
    meanSMD = bal$summary["mean"], maxSMD = bal$summary["max"], n_gt_0.1 = bal$summary["n_gt_0.1"])
  rows[[length(rows)+1L]] <- fitCox(idx, NULL, paste0("1:1 matched - ", nm))
  rows[[length(rows)+1L]] <- fitCox(idx, factor(mm$stratumId), paste0("1:1 matched, stratified - ", nm))
}
tab <- do.call(rbind, rows); rownames(tab) <- NULL
tab$diffFromExact <- tab$logHR - tab$logHR[grep("^1:1 matched - Exact", tab$analysis)]
bal <- do.call(rbind, balrows); rownames(bal) <- NULL
write.csv(tab, file.path(FP_OUT, "phases/tables/phase6_cox.csv"), row.names = FALSE)
write.csv(bal, file.path(FP_OUT, "phases/tables/phase6_balance.csv"), row.names = FALSE)
cat("\n=== Phase 6: balance of the matched sets ===\n"); print(bal, row.names = FALSE, digits = 4)
cat("\n=== Phase 6: Cox hazard ratios (true HR = 1.50) ===\n"); print(tab, row.names = FALSE, digits = 4)
saveRDS(list(cox = tab, balance = bal, trueLogHR = TRUE_LOG_HR), file.path(FP_OUT, "phases/phase6.rds"))
cat("\nPhase 6 complete.\n")
