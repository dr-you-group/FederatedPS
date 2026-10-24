## Summary of dsl_cons.R: DSL vs local, shared and others.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
S <- FP_OUT; DEG <- "ondansetron_promethazine"; set.seed(1); B <- 2000
d <- do.call(rbind, lapply(list.files(file.path(S, "dsl_cons"), pattern = "__[a-z]+\\.csv$", full.names = TRUE), read.csv))
d$err <- d$logHR - d$truth; d$ok <- is.finite(d$logHR) & is.finite(d$se) & d$se < 10 & abs(d$logHR) < 10
d$cov <- abs(d$err) <= 1.96 * d$se
M <- c("local","others","shared","dsl")
d <- d[d$study != DEG & d$method %in% c(M, "crude"), ]
key <- with(d, paste(study, setting, rep, draw, scenario))
d$common <- (tapply(d$ok & d$method %in% M, key, sum) == length(M))[key]
x <- d[d$common & d$method %in% M, ]
cat(sprintf("%d studies, settings %s, %d rows estimable for every method\n", length(unique(x$study)), paste(unique(x$setting), collapse="/"), nrow(x)))

for (sc in c("null","hr2")) { y <- x[x$scenario == sc, ]
  t <- aggregate(cbind(bias = err, mse = err^2, coverage = cov) ~ setting + method, data = y, FUN = mean)
  t$RMSE <- sqrt(t$mse); t$mse <- NULL
  t$MAE50 <- aggregate(e ~ setting + method, data = transform(y, e = abs(err)), FUN = median)$e
  t[, 3:6] <- round(t[, 3:6], 3); cat(sprintf("\n===== %s =====\n", sc)); print(t[order(t$setting, t$method), ], row.names = FALSE) }

## paired comparison RMSE(dsl) / RMSE(m) - 1 with study-level bootstrap (null)
y <- x[x$scenario == "null", ]
W <- reshape(y[, c("study","setting","rep","draw","method","err")], idvar = c("study","setting","rep","draw"), timevar = "method", direction = "wide")
names(W) <- sub("^err\\.", "", names(W))
rel <- function(v, a, b) sqrt(mean(v[[a]]^2)) / sqrt(mean(v[[b]]^2)) - 1
cat("\nDSL vs each method, relative RMSE [95% CI], null:\n")
for (st in sort(unique(W$setting))) { v <- W[W$setting == st, ]; by <- split(v, v$study); ss <- names(by)
  cat(sprintf("  %-8s", st))
  for (m in c("local","shared","others")) { bs <- replicate(B, { s <- do.call(rbind, by[sample(ss, replace = TRUE)]); rel(s, "dsl", m) })
    cat(sprintf("  vs %-6s %+5.1f%% [%+5.1f, %+5.1f]", m, 100*rel(v, "dsl", m), 100*quantile(bs, .025), 100*quantile(bs, .975))) }
  cat("\n") }

## worst-case loss against the best fixed method in each setting
R <- sapply(M, function(m) tapply(seq_len(nrow(W)), W$setting, function(i) sqrt(mean(W[[m]][i]^2))))
reg <- sweep(R, 1, apply(R, 1, min), "/") - 1
cat("\nRMSE by setting and loss (%) against the best method, null:\n"); print(round(R, 3)); print(round(100 * reg, 1))
cat("worst-case loss (%):", paste(sprintf("%s %.1f", colnames(reg), 100 * apply(reg, 2, max)), collapse = " | "), "\n")

## r selected by DSL, per replicate
u <- unique(d[d$method == "dsl", c("study","setting","rep","dslR")])
cat("\nr selected by DSL (replicates):\n"); print(table(u$setting, u$dslR))
## OOF AUC
o <- unique(d[d$method == "local", c("study","setting","rep","oofLocal","oofOthers","oofShared","oofDsl")])
A <- aggregate(cbind(oofLocal, oofOthers, oofShared, oofDsl) ~ setting, data = o, FUN = mean); A[, -1] <- round(A[, -1], 3); cat("\nmean OOF AUC:\n"); print(A)
saveRDS(list(d = d, W = W, R = R), file.path(S, "predict", "dsl_summary.rds"))
