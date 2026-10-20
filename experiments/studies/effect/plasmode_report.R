## Summary of plasmode.R: bias, RMSE, 95% CI coverage and confounder balance after matching.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
SUF <- if (length(commandArgs(TRUE))) commandArgs(TRUE)[1] else ""   # "" or "_cv"
S <- paste0(file.path(FP_OUT, "plasmode"), SUF)
d <- do.call(rbind, lapply(list.files(S, pattern = "_[0-9]+\\.csv$", full.names = TRUE), read.csv))
d$err <- d$logHR - d$truth
d$ok  <- is.finite(d$logHR) & is.finite(d$se) & d$se < 10 & abs(d$logHR) < 10   # |logHR| >= 10: monotone likelihood
d$cov <- abs(d$err) <= 1.96 * d$se
cat(sprintf("%d rows, %d studies, sizes %s\n", nrow(d), length(unique(d$study)), paste(sort(unique(d$size)), collapse = "/")))

## compare on rows where local, shared and partner all gave an estimate
key <- with(d, paste(study, size, rep, draw, scenario))
both <- tapply(d$ok & d$method %in% c("local","shared","partner"), key, sum) == 3
d$common <- both[key]

summ <- function(x) c(n = nrow(x), estimable = mean(x$ok),
  bias = mean(x$err[x$ok]), empSE = sd(x$err[x$ok]), RMSE = sqrt(mean(x$err[x$ok]^2)),
  coverage = mean(x$cov[x$ok]), absSmdZ = mean(abs(x$smdZ[x$ok]), na.rm = TRUE),
  pairs = median(x$pairs[x$ok], na.rm = TRUE))
tab <- function(x, by) { g <- split(x, x[by], drop = TRUE)
  out <- do.call(rbind, lapply(names(g), function(k) c(setNames(strsplit(k, "\\.")[[1]], by), round(summ(g[[k]]), 3))))
  as.data.frame(out) }

for (sc in c("null", "hr2")) {
  x <- d[d$scenario == sc, ]
  cat(sprintf("\n===== scenario %s (true log HR %.3f): fraction estimable =====\n", sc, mean(x$truth)))
  print(round(with(x, tapply(ok, list(size, method), mean)), 2))
  cat("\n-- rows estimable for every method, size x method --\n")
  print(tab(x[x$common, ], c("size", "method")), row.names = FALSE)
}
## per-study RMSE, shared vs local, null
x <- d[d$common & d$scenario == "null", ]
r <- aggregate(err ~ study + size + method, data = x, FUN = function(e) sqrt(mean(e^2)))
w <- reshape(r, idvar = c("study","size"), timevar = "method", direction = "wide")
names(w) <- sub("^err\\.", "", names(w))
w$shared_better <- w$shared < w$local
cat(sprintf("\nnull: cells with RMSE(shared) < RMSE(local): %d / %d\n", sum(w$shared_better), nrow(w)))
print(w[order(w$size, w$study), ], row.names = FALSE, digits = 3)
saveRDS(list(d = d, cells = w), file.path(dirname(S), "predict", paste0("plasmode_summary", SUF, ".rds")))
