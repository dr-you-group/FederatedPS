## Summary of plasmode_cons.R, including choosing a method by OOF AUC.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
SUF <- if (length(commandArgs(TRUE))) commandArgs(TRUE)[1] else ""   # "" or "_cv"
S <- paste0(file.path(FP_OUT, "plasmode_cons"), SUF)
d <- do.call(rbind, lapply(list.files(S, pattern = "__[a-z]+\\.csv$", full.names = TRUE), read.csv))
d$err <- d$logHR - d$truth; d$ok <- is.finite(d$logHR) & is.finite(d$se) & d$se < 10 & abs(d$logHR) < 10   # |logHR| >= 10: monotone likelihood
d$cov <- abs(d$err) <= 1.96 * d$se
key <- with(d, paste(study, setting, rep, draw, scenario))
d$common <- (tapply(d$ok & d$method %in% c("local","others","shared"), key, sum) == 3)[key]
DEG <- "ondansetron_promethazine"
rm2 <- function(e) sqrt(mean(e^2))
cat(sprintf("%d rows, settings %s\n", nrow(d), paste(unique(d$setting), collapse="/")))

x <- d[d$common & d$study != DEG, ]
for (sc in c("null","hr2")) { y <- x[x$scenario == sc, ]
  cat(sprintf("\n===== %s: setting x method, rows estimable for every method =====\n", sc))
  g <- split(y, list(y$setting, y$method), drop = TRUE)
  t <- do.call(rbind, lapply(names(g), function(k) { v <- g[[k]]; p <- strsplit(k, "\\.")[[1]]
    data.frame(setting = p[1], method = p[2], n = nrow(v), bias = mean(v$err), RMSE = rm2(v$err),
      coverage = mean(v$cov), absSmdZ = mean(abs(v$smdZ), na.rm = TRUE)) }))
  t <- t[order(t$setting, t$method), ]; t[, -(1:3)] <- round(t[, -(1:3)], 3); print(t, row.names = FALSE) }

## per-cell RMSE, null
y <- x[x$scenario == "null", ]
cell <- aggregate(err ~ study + setting + method, data = y, FUN = rm2)
w <- reshape(cell, idvar = c("study","setting"), timevar = "method", direction = "wide"); names(w) <- sub("^err\\.", "", names(w))
cat("\ncell-level comparisons, null:\n")
print(do.call(rbind, lapply(split(w, w$setting), function(v) c(n = nrow(v),
  shared_lt_local = sum(v$shared < v$local), others_lt_local = sum(v$others < v$local), shared_lt_others = sum(v$shared < v$others)))))

## choose the method with the highest OOF AUC in each replicate
y$pickJoin <- ifelse(y$oofShared > y$oofLocal, "shared", "local")                       # local vs shared only
y$pick3 <- c("local","others","shared")[max.col(cbind(y$oofLocal, y$oofOthers, y$oofShared), "first")]
strat <- function(v) { u <- unique(v[, c("rep","draw","pickJoin","pick3")])
  get <- function(m) v$err[v$method == m][match(paste(u$rep,u$draw), paste(v$rep,v$draw)[v$method == m])]
  E <- sapply(c("local","others","shared"), get)
  cj <- E[cbind(seq_len(nrow(u)), match(u$pickJoin, colnames(E)))]
  c3 <- E[cbind(seq_len(nrow(u)), match(u$pick3, colnames(E)))]
  c(always_local = rm2(E[,"local"]), always_others = rm2(E[,"others"]), always_shared = rm2(E[,"shared"]),
    pick_join = rm2(cj), pick_3way = rm2(c3)) }
cat("\nselection by OOF AUC vs fixed methods, mean cell RMSE, null:\n")
R <- do.call(rbind, lapply(split(y, list(y$study, y$setting), drop = TRUE), function(v)
  data.frame(study = v$study[1], setting = v$setting[1], t(strat(v)))))
R$oracle <- apply(R[, c("always_local","always_others","always_shared")], 1, min)
A <- aggregate(. ~ setting, data = R[, -1], FUN = mean); A[, -1] <- round(A[, -1], 4); print(A, row.names = FALSE)
cat("\ncells where selection beats always_local:\n"); print(table(R$setting, R$pick_3way < R$always_local))
cat("\nloss of selection against the best fixed method (mean, % of cell RMSE):\n")
print(round(tapply(100*(R$pick_3way/R$oracle - 1), R$setting, mean), 1))

## cell-level correlation between AUC and RMSE differences
oa <- aggregate(cbind(oofLocal, oofOthers, oofShared) ~ study + setting, data = y[y$method=="local",], FUN = mean)
m <- merge(w, oa, by = c("study","setting"))
cat(sprintf("\nSpearman: (OOF shared-local) vs (RMSE local-shared) = %.2f, (OOF shared-others) vs (RMSE others-shared) = %.2f\n",
  cor(m$oofShared - m$oofLocal, m$local - m$shared, method = "spearman"),
  cor(m$oofShared - m$oofOthers, m$others - m$shared, method = "spearman")))
cat("\nmean OOF AUC by setting:\n"); B <- aggregate(cbind(oofLocal, oofOthers, oofShared) ~ setting, data = m, FUN = mean); B[, -1] <- round(B[, -1], 3); print(B)
saveRDS(list(d = d, cells = w, strat = R), paste0(file.path(FP_OUT, "predict/plasmode_cons_summary"), SUF, ".rds"))
