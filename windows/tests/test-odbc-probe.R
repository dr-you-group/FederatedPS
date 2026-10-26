source('windows/odbc-probe-checks.R')
expect_error <- function(expr,pattern) {
    failure <- tryCatch({force(expr);NULL},error=function(e)e)
    stopifnot(inherits(failure,'error'),grepl(pattern,conditionMessage(failure),fixed=TRUE))
}
fixture <- function(bad=NULL) {
    session <- new.env(parent=emptyenv());session$cleared <- 0L;session$executed <- character();session$sent <- character()
    event <- function(label,state) invisible(NULL)
    api <- list(
      send=function(con,sql) {
        stopifnot(identical(con,session));session$sent <- c(session$sent,sql)
        if(grepl('CARE_SITE',sql,fixed=TRUE)) {
            id <- as.integer(sub('.*CARE_SITE_ID = ([0-9]+);','\\1',sql))
            data <- data.frame(careSiteId=if(identical(bad,'wrong-site'))99L else id)
            if(identical(bad,'duplicate-site'))data <- rbind(data,data)
        } else if(grepl('big_id, korean',sql,fixed=TRUE)) {
            data <- data.frame(big_id=if(identical(bad,'rounded-bigint'))'9007199254740992' else '9007199254740993',
                korean=if(identical(bad,'encoding'))'??' else '\uD55C\uAE00',empty_value=NA_character_)
        } else if(grepl('CAST(1 AS INT)',sql,fixed=TRUE))data <- data.frame(ok=1L,sessionId=17L)
        else data <- data.frame(sessionId=if(identical(bad,'session-change'))18L else 17L)
        list(data=data)
      },
      fetch=function(result,n) {stopifnot(n==3L);result$data},
      done=function(result) !identical(bad,'incomplete'),
      clear=function(result) {session$cleared <- session$cleared+1L;TRUE},
      execute=function(con,sql) {stopifnot(identical(con,session));session$executed <- c(session$executed,sql);1L}
    )
    list(con=session,api=api,event=event)
}
run <- function(f)fp_odbc_probe_checks(f$con,1:3,'CDM54_2601.CDM',f$event,f$api)
f <- fixture();checks <- run(f)
stopifnot(identical(checks,c('self-check','site-1','site-2','site-3','typed-temp-table','same-session','temp-cleanup')),
    f$con$cleared==6L,length(f$con$executed)==3L,
    all(grepl('#fps_odbc_probe',f$con$executed,fixed=TRUE)))
for(case in c('wrong-site','duplicate-site'))expect_error(run(fixture(case)),'CARE_SITE')
for(case in c('rounded-bigint','encoding'))expect_error(run(fixture(case)),'conversion failed')
expect_error(run(fixture('session-change')),'Physical session changed')
f <- fixture('incomplete');expect_error(run(f),'not exhausted');stopifnot(f$con$cleared==1L)
f <- fixture();expect_error(fp_odbc_probe_checks(f$con,1:3,'bad;schema',f$event,f$api),'Invalid schema')
stopifnot(!length(f$con$sent))
# Production callback exercises the actual package query rather than silently
# switching back to a native-only self-check. Temporary tables still use DBI.
f <- fixture();smallCalls <- 0L
small <- function(con,sql,columns) {
    smallCalls <<- smallCalls+1L
    if(identical(names(columns),c('ok','sessionId')))data.frame(ok=1L,sessionId=17L)
    else data.frame(careSiteId=as.integer(sub('.*CARE_SITE_ID = ([0-9]+);','\\1',sql)))
}
checks <- fp_odbc_probe_checks(f$con,1:3,'CDM54_2601.CDM',f$event,f$api,small)
stopifnot(smallCalls==4L,length(checks)==7L,f$con$cleared==2L)
cat('PASS: ODBC probe strict types, site IDs, one session, EOF, cleanup and production callback\n')
f <- fixture();f$api$clear <- function(result) FALSE
expect_error(run(f),'clear result')
event <- function(...)invisible(NULL)
stopifnot(isTRUE(fp_odbc_probe_disconnect(list(),event,disconnect=function(x)TRUE,valid=function(x)FALSE)))
expect_error(fp_odbc_probe_disconnect(list(),event,disconnect=function(x)FALSE,valid=function(x)FALSE),'report success')
expect_error(fp_odbc_probe_disconnect(list(),event,disconnect=function(x)TRUE,valid=function(x)TRUE),'remains valid')
examples <- c(
 '28000 [Microsoft][SQL Server]Login failed for user secret-user (18456)'='authentication-rejected',
 '08001 SSL Provider: certificate chain was issued by an authority not trusted; server=secret-host'='tls-certificate-or-protocol',
 'HYT00 Login timeout expired uid=secret-user'='odbc-timeout',
 '08S01 TCP connection failure'='network-or-endpoint',
 'IM002 Data source not found'='odbc-driver-missing-or-architecture',
 'Missing/unloadable package odbc; run APPLY_ODBC.ps1'='r-dependency-missing',
 'Missing connection fields: DB_PASSWORD'='connection-config-invalid',
 '42S02 Invalid object name secret-table'='sql-permission-schema-or-syntax')
for(i in seq_along(examples)) {
 result <- fp_odbc_probe_error(simpleError(names(examples)[i]))
 stopifnot(identical(result$category,unname(examples[i])),!grepl('secret',paste(unlist(result),collapse=' ')))
}
stopifnot(identical(fp_odbc_probe_error(simpleError('Missing connection fields: DB_PASSWORD'))$configFields,'DB_PASSWORD'))
cat('PASS: strict cleanup and sanitized SQLSTATE/error categories\n')
