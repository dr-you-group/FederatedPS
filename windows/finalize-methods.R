# Map validated federated design results back to the SAME prepared populations.
args <- commandArgs(trailingOnly=TRUE)
stopifnot(length(args)==1L)
config <- jsonlite::fromJSON(args[1])
source(file.path(config$project,"windows","baseline-models.R"))
stopifnot("federated" %in% config$methods,
    file.exists(file.path(config$federatedOutput,"SUCCESS.txt")))
fedConfig <- jsonlite::fromJSON(file.path(config$federatedOutput,"run.json"))
stopifnot(identical(fedConfig$mode,"Design"), identical(fedConfig$runId,config$runId),
    identical(fedConfig$sites,config$sites))
common <- readRDS(file.path(config$federatedOutput,"aggregator","result.rds"))
summaries <- list()
for (site in config$sites) {
    design <- readRDS(file.path(config$output,"prepared",paste0(site,".rds")))
    fit <- readRDS(file.path(config$federatedOutput,site,"result.rds"))
    result <- fp_map_federated_result(design,fit,common,config)
    summaries[[site]] <- fp_baseline_save(result,file.path(config$output,"federated",site),"federated",site)
}
path <- file.path(config$output,"summary.csv")
previous <- tryCatch(utils::read.csv(path),error=function(e)data.frame())
summary <- do.call(rbind,summaries)
if(ncol(previous)) summary <- rbind(previous,summary)
utils::write.csv(summary,path,row.names=FALSE)
jsonlite::write_json(list(runId=config$runId,state="federated-mapped",sites=config$sites),
    file.path(config$output,"federated-mapped.json"),auto_unbox=TRUE,pretty=TRUE)
cat("PASS: federated results mapped to identical prepared patients and verified against coefficients\n")
