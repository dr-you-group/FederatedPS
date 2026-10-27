# Isolated preflight of the SAME complete SQL preparation used by the analysis.
# No credentials are read and no database connection is opened.
args <- commandArgs(trailingOnly=TRUE)
stopifnot(length(args)==1L)
project <- normalizePath(args[1],winslash="/",mustWork=TRUE)
source(file.path(project,"windows","common.R"))
fp_verify_runtime(project)
prepare <- utils::getFromNamespace(".fpsPrepareCareSiteSqlPlan","FederatedPs")
settings <- FederatedPs::getStudySettings("ppi","default")
cat("START: complete local SQL preparation (no DB)\n");flush(stdout())
for (site in 1:3) {
    plan <- prepare("CDM54_2601.CDM",settings,site,c(200L,100L,300L)[site])
    stopifnot(length(plan$batches[["SitePartition.sql"]]$statements)==4L,
              length(plan$batches[["CohortMethod GetCohorts.sql"]]$statements)==1L)
    cat("PASS: complete SQL plan site_id=",site," files=",length(plan$batches),"\n",sep="")
    flush(stdout())
}
cat("PASS: local SQL plans; live database execution is tested by RUN.ps1.\n")
quit(save="no",status=0L,runLast=FALSE)
