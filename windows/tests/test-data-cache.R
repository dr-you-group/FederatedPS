source("windows/data-cache.R")
source("windows/baseline-models.R")
source("R/StudySettings.R");source("R/CareSiteData.R");source("R/SyntheticYuhs.R")
error <- function(expr,pattern) {
    e <- tryCatch({force(expr);NULL},error=identity)
    stopifnot(inherits(e,"error"),grepl(pattern,conditionMessage(e)))
}
for(value in list(NULL,NA,Inf,1,-1,1.5,"200",2147483648)) error(.validatePatientLimit(value),"patientLimit")
stopifnot(.validatePatientLimit(0)==0L,.validatePatientLimit(200)==200L)
cdm <- .readSyntheticYuhsCdm("inst/extdata/yuhs-synthetic")
t <- .prepareSyntheticYuhsTables(cdm,1)
for(limit in c(0,2,3,20,200)) {
    pop <- fp_limit_synthetic_population(t$cohorts,limit)
    stopifnot(nrow(pop)==if(limit==0)120 else min(limit,120),setequal(pop$treatment,0:1),!anyDuplicated(pop$personId))
    if(limit>0 && limit<120) stopifnot(abs(diff(table(pop$treatment)))<=1)
    shuffled <- t$cohorts[rev(seq_len(nrow(t$cohorts))),]
    if(limit<120 && limit>0) stopifnot(identical(as.character(pop$personId),as.character(fp_limit_synthetic_population(shuffled,limit)$personId)))
}
pop <- fp_limit_synthetic_population(t$cohorts,20)
design <- fp_baseline_design(pop,t$covariates,t$covariateRef,t$analysisRef,t$metaData,"severance")
out <- tempfile("fps-cache-test-");dir.create(out)
config <- list(project=getwd(),test=TRUE,study="ppi",scenario="default",sites=c("severance","gangnam","yongin"),
    careSites=list(severance=1,gangnam=2,yongin=3),patientLimit=20)
contract <- fp_data_contract(config,runtimeVersions=c(FederatedPs="fixture"))
stopifnot(is.null(fp_cache_read(out,contract,"severance")))
path <- fp_cache_write(out,contract,"severance",design)
loaded <- fp_cache_read(out,contract,"severance")
stopifnot(identical(loaded$design,design),identical(loaded$path,path))
changed <- contract;changed$patientLimit <- 200L
stopifnot(is.null(fp_cache_read(out,changed,"severance")))
changed <- contract;changed$test <- FALSE
stopifnot(is.null(fp_cache_read(out,changed,"severance")))
changed <- contract;changed$connectionHash <- "other-database"
stopifnot(is.null(fp_cache_read(out,changed,"severance")))
changed <- config;changed$methods <- "federated";changed$blockSize <- 4;changed$alpha <- 0.5
stopifnot(identical(contract,fp_data_contract(changed,runtimeVersions=c(FederatedPs="fixture"))))
# A crash mid-write must never produce a reusable checkpoint.
parent <- file.path(out,fp_object_md5(contract),"gangnam")
dir.create(file.path(parent,"entry-incomplete.partial"),recursive=TRUE)
saveRDS(design,file.path(parent,"entry-incomplete.partial","design.rds"))
stopifnot(is.null(fp_cache_read(out,contract,"gangnam")))
# Damaged completed checkpoint must fail, rather than silently run on bad data.
cat("tamper",file=file.path(path,"design.rds"),append=TRUE)
error(fp_cache_read(out,contract,"severance"),"checksum")
# Rebuild writes a fresh generation without changing/destroying old one.
newPath <- fp_cache_write(out,contract,"severance",design)
stopifnot(newPath!=path,dir.exists(path),identical(fp_cache_read(out,contract,"severance")$design,design))
# Limits belong to the individual site key, not the shared model contract.
perSite <- config;perSite$sites <- c("1","2","3");perSite$careSites <- list(`1`=1,`2`=2,`3`=3);perSite$patientLimits <- list(`1`=20,`2`=10,`3`=30)
one <- fp_data_contract(perSite,runtimeVersions=c(FederatedPs="fixture"),site="1")
two <- fp_data_contract(perSite,runtimeVersions=c(FederatedPs="fixture"),site="2")
perSite$patientLimits[["2"]] <- 40
stopifnot(identical(one,fp_data_contract(perSite,runtimeVersions=c(FederatedPs="fixture"),site="1")),
    !identical(two,fp_data_contract(perSite,runtimeVersions=c(FederatedPs="fixture"),site="2")))
siteNames <- c("1","2","3")
differentLimits <- setNames(lapply(seq_along(siteNames),function(i){
    d <- .prepareSyntheticYuhsTables(cdm,i)
    p <- fp_limit_synthetic_population(d$cohorts,c(20,10,30)[i])
    m <- d$metaData;m$patientLimit <- c(20,10,30)[i]
    fp_baseline_design(p,d$covariates,d$covariateRef,d$analysisRef,m,siteNames[i])
}),siteNames)
fp_baseline_validate_sites(differentLimits)
stopifnot(nrow(fp_baseline_pool(differentLimits)$x)==60)
unlink(out,recursive=TRUE)
sql <- paste(readLines("inst/sql/sql_server/LimitPatients.sql"),collapse="\n")
stopifnot(grepl("TOP (@patient_limit)",sql,fixed=TRUE),grepl("PARTITION BY subject_id",sql,fixed=TRUE),
    grepl("DELETE e FROM #fps_exposure e",sql,fixed=TRUE),!grepl("DELETE.*@cdm_database_schema",sql))
body <- paste(deparse(body(.getCareSiteStudyData)),collapse="\n")
stopifnot(regexpr('execute("LimitPatients.sql"',body,fixed=TRUE)<regexpr('step(6,',body,fixed=TRUE))
cat("PASS: per-site caps, balanced deterministic sample, completed-cache reuse, settings isolation, partial-write rejection, corruption detection, rebuild generation\n")
