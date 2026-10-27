source("windows/baseline-models.R")
error <- function(expr, pattern) {
    e <- tryCatch({force(expr);NULL}, error=identity)
    stopifnot(inherits(e,"error"), grepl(pattern,conditionMessage(e)))
}
analysis <- data.frame(analysisId=1, analysisName="binary", domainId="Condition", isBinary="Y", missingMeansZero="Y")
metadata <- list(targetId=1, comparatorId=2, studyDefinition=list(featureDefinition="care-site-binary-v1"))
make <- function(site, persons, features) {
    population <- data.frame(rowId=c(20,10),personId=persons,treatment=c(1,0))
    reference <- data.frame(covariateId=features,analysisId=1,conceptId=features/1000)
    covariates <- data.frame(rowId=c(20,10),covariateId=features,covariateValue=c(2,1))
    fp_baseline_design(population,covariates,reference,analysis,metadata,site)
}
a <- make("severance",c("102","101"),c(10001,20001))
b <- make("gangnam",c("202","201"),c(20001,30001))
c <- make("yongin",c("302","301"),c(10001,30001))
designs <- list(severance=a,gangnam=b,yongin=c)
fp_baseline_validate_sites(designs)
stopifnot(identical(a$population$personId,c("101","102")),
    identical(rownames(a$x),c("severance:10","severance:20")),
    identical(as.matrix(a$x),matrix(c(0,2,1,0),2,2,dimnames=dimnames(a$x))))
pooled <- fp_baseline_pool(designs)
stopifnot(nrow(pooled$x)==6, ncol(pooled$x)==3, !anyDuplicated(rownames(pooled$x)),
    identical(pooled$population$personId,c("101","102","201","202","301","302")),
    identical(colnames(pooled$x),c("10001","20001","30001")),
    all(pooled$x[1:2,"30001"]==0), all(pooled$x[3:4,"10001"]==0),
    all(pooled$x[5:6,"20001"]==0))
bad <- designs; bad$gangnam$population$personId[1] <- "101"
error(fp_baseline_pool(bad),"overlap")
bad <- designs; bad$gangnam$metadata$studyDefinition$featureDefinition <- "other"
error(fp_baseline_pool(bad),"different study")
bad <- designs; bad$gangnam$reference$conceptId[1] <- "999999"
error(fp_baseline_pool(bad),"Conflicting")
pop <- data.frame(rowId=1:2, personId=c("1","2"),treatment=0:1)
ref <- data.frame(covariateId=10001,analysisId=1,conceptId=10)
cov <- data.frame(rowId=c(1,1),covariateId=c(10001,10001),covariateValue=c(1,1))
error(fp_baseline_design(pop,cov,ref,analysis,metadata,"s"),"Duplicate")
cov <- cov[1,,drop=FALSE];cov$covariateValue <- Inf
error(fp_baseline_design(pop,cov,ref,analysis,metadata,"s"),"non-finite")
error(fp_baseline_ids(c("10001","bad")),"Feature IDs")
error(fp_baseline_ids(2^54),"Feature IDs")
coef <- setNames(c(-0.2,0.3,-0.4,0.5),c("(Intercept)",colnames(pooled$x)))
scores <- fp_baseline_predict(pooled$x,coef)
stopifnot(max(abs(scores-plogis(-0.2+as.numeric(pooled$x %*% coef[-1]))))<1e-14)
error(fp_baseline_predict(pooled$x,rev(coef)),"Coefficient")
out <- tempfile("baseline-test-");dir.create(out)
result <- list(population=pooled$population,coefficients=coef,features=colnames(pooled$x),
    iterations=7L,fitSeconds=1,returnFlag="SUCCESS",priorVariance=1,
    blockSize=1,alpha=1,crossValidation=FALSE,predictionType="in-sample",exchangeRounds=0L)
result$population$propensityScore <- scores
summary <- fp_baseline_save(result,out,"pooled","all")
fp_baseline_verify(pooled,out)
stopifnot(summary$n==6,summary$treated==3,summary$comparator==3,
    summary$predictionType=="in-sample",file.exists(file.path(out,"coefficients.csv")))
bad <- readRDS(file.path(out,"result.rds"));bad$personId <- rev(bad$personId);saveRDS(bad,file.path(out,"result.rds"))
error(fp_baseline_verify(pooled,out),"mapping")
saveRDS(result$population,file.path(out,"result.rds"))
bad <- result$population;bad$propensityScore[1] <- 0.999;saveRDS(bad,file.path(out,"result.rds"))
error(fp_baseline_verify(pooled,out),"PS values")
unlink(out,recursive=TRUE)
# Mixed-mode federation must map predictions back to these exact patients,
# including global features absent from one site's matrix.
fit <- list(rowIds=a$population$rowId,coefficients=coef,
    propensityScore=fp_baseline_predict(a$x,coef[c("(Intercept)",colnames(a$x))]),
    iterations=7L,fitSeconds=1,rounds=12L)
mapped <- fp_map_federated_result(a,fit,coef,list(blockSize=1,alpha=1))
stopifnot(identical(mapped$population$personId,a$population$personId),
    identical(mapped$coefficients,coef),mapped$exchangeRounds==12L)
bad <- fit;bad$rowIds <- rev(bad$rowIds)
error(fp_map_federated_result(a,bad,coef,list()),"row mapping")
bad <- fit;bad$propensityScore[1] <- 0.99
error(fp_map_federated_result(a,bad,coef,list()),"PS do not match")
bad <- fit;bad$coefficients <- coef[-2]
error(fp_map_federated_result(a,bad,coef[-2],list()),"omitted a nonzero")
zero <- a;zero$x <- cbind(zero$x,`40001`=Matrix::Matrix(0,nrow=2,ncol=1,sparse=TRUE))
stopifnot(identical(fp_map_federated_result(zero,fit,coef,list(blockSize=1,alpha=1))$population,
    mapped$population))
# Real invented CDM tables: validates site partition and design/pool mapping
# without any database or installed Cyclops/Andromeda dependency.
source("R/StudySettings.R");source("R/CareSiteData.R");source("R/SyntheticYuhs.R")
cdm <- .readSyntheticYuhsCdm("inst/extdata/yuhs-synthetic")
synthetic <- setNames(lapply(1:3,function(i){
    t <- .prepareSyntheticYuhsTables(cdm,i)
    fp_baseline_design(t$cohorts,t$covariates,t$covariateRef,t$analysisRef,t$metaData,names(designs)[i])
}),names(designs))
all <- fp_baseline_pool(synthetic)
stopifnot(nrow(all$x)==360, !anyDuplicated(all$population$personId),
    setequal(all$population$treatment,0:1), all(table(all$population$site)==120))
cat("PASS: local/pool row and feature alignment, zero fill, study contracts, disjoint persons, saved PS verification, 360-person synthetic fixture\n")
