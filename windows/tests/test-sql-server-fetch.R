source("R/SqlServerFetch.R")
source("R/SqlProgress.R")
# Test the streaming boundary without a SQL Server/Andromeda dependency.
# The API supplies DatabaseConnector's typed rows and normalization in production.
fixture <- function(batches, fail=NULL) {
    e <- new.env();e$i<-0L;e$clears<-0L;e$sizes<-integer();e$normalized<-0L
    e$api <- list(batchSize=-2L,
        send=function(connection,sql) {if(identical(fail,"send"))stop("send error");e},
        fetch=function(result,n) {
            e$i<-e$i+1L;e$sizes<-c(e$sizes,n)
            if(identical(fail,"fetch"))stop("fetch error")
            batches[[e$i]]
        }, done=function(result) e$i>=length(batches),
        clear=function(result) {e$clears<-e$clears+1L;if(identical(fail,"clear"))stop("clear error")},
        normalize=function(data) {e$normalized<-e$normalized+1L;data})
    e
}
batches <- list(data.frame(rowId=c(1,2),value=c(NA_real_,3.5)),data.frame(rowId=3,value=4.5))
e<-fixture(batches);seen<-list();flags<-logical()
.fpsFetchSqlServer(NULL,"SELECT fixture",function(batch,first){seen[[length(seen)+1L]]<<-batch;flags<<-c(flags,first)},e$api)
stopifnot(identical(seen,batches),identical(flags,c(TRUE,FALSE)),e$clears==1L,e$normalized==2L,
    identical(e$sizes,c(-2L,-2L)))
empty<-batches[[1]][FALSE,];e<-fixture(list(empty));seen<-NULL
.fpsFetchSqlServer(NULL,"SELECT empty",function(batch,first){stopifnot(first);seen<<-batch},e$api)
stopifnot(identical(seen,empty),e$clears==1L,e$i==1L)
e<-fixture(batches)
stopifnot(identical(.fpsFetchSqlServer(NULL,"SELECT all",api=e$api),batches[[1]]),
    identical(e$sizes,-1L),e$clears==1L)
for (fail in c("send","fetch","clear")) {
    e<-fixture(batches,fail)
    result<-try(.fpsFetchSqlServer(NULL,"SELECT fail",api=e$api),silent=TRUE)
    stopifnot(inherits(result,"try-error"),grepl(paste(fail,"error"),result),e$clears==as.integer(fail!="send"))
}
e<-fixture(batches,"clear")
original<-simpleError("consumer error")
result<-tryCatch(.fpsFetchSqlServer(NULL,"SELECT fail",function(...)stop(original),e$api),error=identity)
stopifnot(identical(result,original),e$clears==1L)
# Prepared DDL/DML must execute once with cleanup, without splitting/replaying.
for (fail in c("none","executeLargeUpdate","close")) {
    calls<-character()
    jcall<-function(object,type,method,...) {
        calls<<-c(calls,method)
        if(method==fail)stop(paste(method,"failed"))
        if(method=="createStatement")"statement" else 123L
    }
    result<-try(.fpsJdbcExecutePrepared("connection","SELECT 1 INTO #fixture",jcall),silent=TRUE)
    stopifnot(identical(calls,c("createStatement","executeLargeUpdate","close")))
    if(fail=="none")stopifnot(result==123L) else stopifnot(inherits(result,"try-error"))
}
cat("PASS: streaming batch size/order, typed empty table, NULL values, numeric result, cleanup and error preservation; direct JDBC single execution\n")
