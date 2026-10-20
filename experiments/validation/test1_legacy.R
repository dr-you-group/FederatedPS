source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "validation/common.R"))
set.seed(11); n <- 400L; d <- 25L
Xd <- matrix(rbinom(n*d, 1, 0.35), n, d)
y  <- rbinom(n, 1, 1/(1+exp(-(-0.3 + Xd %*% c(1.2,-0.9,0.7,rep(0,d-3))))))
X  <- cbind(1, Xd); lam <- lambdaOf(1)

which <- commandArgs(trailingOnly = TRUE)[1]
useCyclops(which)
cat("Cyclops build:", which, " version", as.character(packageVersion("Cyclops")),
    " lib:", dirname(find.package("Cyclops")), "\n")
cat("blockSize in createControl formals:",
    "blockSize" %in% names(formals(Cyclops::createControl)), "\n")

a <- runFit(X, y, P = 1L, alpha = 1, aggregate = TRUE,  keepTrace = TRUE)
b <- runFit(X, y,                     aggregate = FALSE)
s <- pooledStats(a$beta, X, y, lam)
cat(sprintf("aggregate P=1 a=1 : flag=%s iter=%d nnz=%d obj=%.12f kkt=%.6e exchanges=%d (coord %d + conv %d)\n",
    a$flag, a$iterations, s$nnz, s$obj, s$kkt, a$rec$n, a$rec$nLoopCoord, a$rec$nConv))
cat(sprintf("no aggregate      : flag=%s iter=%d  max|diff vs aggregate| = %.3e\n",
    b$flag, b$iterations, max(abs(a$beta - b$beta))))
cat(sprintf("packet lengths seen: %s\n", paste(sort(unique(sapply(a$rec$trace, function(t) length(t$s)))), collapse=", ")))
saveRDS(list(beta=a$beta, iter=a$iterations, trace=a$rec$trace, n=a$rec$n,
             nCoord=a$rec$nLoopCoord, nConv=a$rec$nConv, obj=s$obj, nnz=s$nnz, kkt=s$kkt),
        sprintf(file.path(FP_OUT, "validation/t1_%s.rds"), which))
