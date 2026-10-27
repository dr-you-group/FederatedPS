source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "validation/common.R")); useCyclops("patched")
set.seed(23); n <- 600L; d <- 60L
Xd <- matrix(rbinom(n*d, 1, 0.3), n, d)
truth <- c(1.5,-1.2,0.9, rep(0, d-3))          # 3 of 60 nonzero
y <- rbinom(n, 1, 1/(1+exp(-(-0.4 + Xd %*% truth))))
X <- cbind(1, Xd); lam <- lambdaOf(1)

## ---- R version of the block loop, with alpha applied either inside the prox step or after it
rawDelta <- function(g,h,b,pen,lam){
  if(!is.finite(h)||h<=0) return(0)
  if(!pen) return(-g/h)
  nu <- -(g-lam)/h; pu <- -(g+lam)/h; s <- sign(b)
  if(s==0){ if(nu<0) nu else if(pu>0) pu else 0
  } else { dl <- if(s<0) nu else pu; if(sign(b+dl)!=s) -b else dl }
}
blockR <- function(X,y,P,alpha,mode,lam,maxPass=500L,tol=1e-6){
  d<-ncol(X); beta<-numeric(d); bnd<-rep(2,d); eta<-numeric(nrow(X)); prev<-NULL
  blocks<-split(seq_len(d), ceiling(seq_len(d)/P))
  for(pass in seq_len(maxPass)){
    for(blk in blocks){
      p<-1/(1+exp(-eta))
      g<-as.vector(crossprod(X[,blk,drop=FALSE], p-y))
      h<-as.vector(crossprod(X[,blk,drop=FALSE]^2, p*(1-p)))
      del<-numeric(length(blk))
      for(i in seq_along(blk)){ j<-blk[i]; pen <- j!=1L
        if(mode=="prox"){ dl<-rawDelta(g[i], h[i]/alpha, beta[j], pen, lam)
        } else {          dl<-alpha*rawDelta(g[i], h[i], beta[j], pen, lam) }
        dl<-max(-bnd[j],min(bnd[j],dl)); del[i]<-dl
        bnd[j]<-max(2*abs(dl)/alpha, bnd[j]/2, 1e-3) }
      if(any(del!=0)){ beta[blk]<-beta[blk]+del; eta<-eta+as.vector(X[,blk,drop=FALSE]%*%del) }
    }
    e<-as.vector(X%*%beta); o<- -(sum(y*e-log1p(exp(e))) - lam*sum(abs(beta[-1])))
    if(!is.null(prev) && abs(o-prev)/(abs(o)+1)<tol) break
    prev<-o }
  list(beta=beta, passes=pass)
}

cat("=== single-update demonstration ===\n")
demo <- function(b0, g, h, alpha) {
  dl <- rawDelta(g, h, b0, TRUE, lam)                 # exact (undamped) step
  post <- b0 + alpha*dl                               # post-hoc damping
  pz <- rawDelta(g, h/alpha, b0, TRUE, lam)           # proximal damping
  prox <- b0 + pz
  cat(sprintf("  beta=%-5.3f g=%-5.2f h=%-4.1f alpha=%.2f | exact delta=%-8.4f beta+delta=%.2e\n",
              b0, g, h, alpha, dl, b0+dl))
  cat(sprintf("      post-hoc  beta + alpha*delta = %-12.6g  exactly zero: %s\n", post, post == 0))
  cat(sprintf("      proximal  soft(.)            = %-12.6g  exactly zero: %s\n", prox, prox == 0))
}
cat("  (a) coefficient that should be shrunk to zero this step:\n")
demo(0.05, 0.10, 2.0, 0.5)
cat("  (b) coefficient still far from zero -- proximal takes a smaller step, not zero:\n")
demo(0.40, 0.10, 2.0, 0.5)
cat("\n  General fact: when the exact step is delta = -beta, post-hoc damping gives\n")
cat("  beta + alpha*(-beta) = (1-alpha)*beta, which is zero only when alpha = 1.\n")
cat("  The proximal form clips to exactly zero whenever |beta - alpha*g/h| <= alpha*lambda/h.\n\n")

cat("\n=== full run, P = 10, alpha = 0.5 ===\n")
ex <- runFit(X, y, P = 1L,  alpha = 1,   aggregate = TRUE)         # exact baseline
pr <- runFit(X, y, P = 10L, alpha = 0.5, aggregate = TRUE)         # C++ proximal block
rp <- blockR(X, y, 10L, 0.5, "prox",  lam)                         # R mirror, proximal
rs <- blockR(X, y, 10L, 0.5, "scale", lam)                         # R mirror, post-hoc
row <- function(tag,b,extra="") cat(sprintf("  %-28s nnz = %3d / %d   min|nonzero| = %.3e %s\n",
     tag, sum(b!=0), length(b), if(any(b!=0)) min(abs(b[b!=0])) else NA, extra))
row("exact baseline P=1 a=1", ex$beta)
row("C++ proximal block", pr$beta, sprintf("max|diff vs R mirror| = %.2e", max(abs(pr$beta-rp$beta))))
row("R mirror proximal", rp$beta)
row("R mirror POST-HOC damping", rs$beta)
cat(sprintf("\n  support(exact) == support(C++ proximal block) : %s\n",
            identical(which(ex$beta!=0), which(pr$beta!=0))))
cat(sprintf("  extra spurious nonzeros, post-hoc vs exact     : %d\n",
            sum(rs$beta!=0) - sum(ex$beta!=0)))
cat(sprintf("  coordinates that post-hoc failed to zero       : %d\n",
            sum(ex$beta==0 & rs$beta!=0)))
