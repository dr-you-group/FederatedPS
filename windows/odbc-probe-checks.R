# The only write is a connection-local temporary table containing invented data.
# No patient rows or connection strings are included in the diagnostic output.
fp_odbc_probe_checks <- function(connection, siteIds, schema, event,
        api = list(send=DBI::dbSendQuery,fetch=DBI::dbFetch,done=DBI::dbHasCompleted,
                   clear=DBI::dbClearResult,execute=DBI::dbExecute), smallQuery=NULL) {
    if (!grepl("^[A-Za-z_][A-Za-z0-9_]*[.][A-Za-z_][A-Za-z0-9_]*$",schema))
        stop("Invalid schema")
    if (!length(siteIds) || anyNA(siteIds) || anyDuplicated(siteIds) ||
        any(siteIds < 1 | siteIds > .Machine$integer.max | siteIds != floor(siteIds)))
        stop("Invalid site IDs")
    checks <- character()
    run <- function(label,expr) {
        event(label,"started")
        answer <- force(expr)
        event(label,"completed")
        answer
    }
    passed <- function(label) { checks <<- c(checks,label); event(label,"validated") }
    query <- function(label,sql) {
        result <- NULL
        on.exit(if(!is.null(result)) try(run(paste(label,"clear after failure"),api$clear(result)),silent=TRUE))
        result <- run(paste(label,"send"),api$send(connection,sql))
        rows <- run(paste(label,"fetch"),api$fetch(result,n=3L))
        if (!is.data.frame(rows) || nrow(rows)>2L) stop("Unexpected probe row count")
        if (!isTRUE(run(paste(label,"EOF"),api$done(result)))) stop("Probe result not exhausted")
        if(!isTRUE(run(paste(label,"clear"),api$clear(result)))) stop("Could not clear result")
        result <- NULL
        rows
    }
    checkQuery <- function(label,sql,columns) {
        if(is.null(smallQuery)) query(label,sql) else
            run(paste(label,"package DBI query"),smallQuery(connection,sql,columns))
    }
    first <- checkQuery("SELECT 1 and session", "SELECT CAST(1 AS INT) AS ok, @@SPID AS sessionId;",
                        c(ok="integer",sessionId="integer"))
    if(nrow(first)!=1L || ncol(first)!=2L || !identical(as.integer(first[[1]]),1L) ||
       length(first[[2]])!=1L || is.na(first[[2]]) || first[[2]]<=0) stop("Invalid self-check")
    session <- as.integer(first[[2]]);passed("self-check")
    for(id in siteIds) {
        label <- paste0("CARE_SITE site_id=",id)
        data <- checkQuery(label,paste0("SELECT TOP (2) CARE_SITE_ID AS careSiteId FROM ",schema,
                    ".CARE_SITE WHERE CARE_SITE_ID = ",id,";"),c(careSiteId="integer"))
        if(nrow(data)!=1L || ncol(data)!=1L || !identical(as.integer(data[[1]]),as.integer(id)))
            stop("CARE_SITE must contain exactly one matching ID")
        passed(paste0("site-",id))
    }
    run("Temporary table create",api$execute(connection,
        "CREATE TABLE #fps_odbc_probe (big_id BIGINT NOT NULL, korean NVARCHAR(32) NOT NULL, empty_value NVARCHAR(8) NULL);"))
    run("Temporary table insert synthetic row",api$execute(connection,
        paste0("INSERT INTO #fps_odbc_probe (big_id,korean,empty_value) VALUES (9007199254740993,N'",
               "\uD55C\uAE00","',NULL);")))
    typed <- query("Temporary table typed fetch","SELECT big_id, korean, empty_value FROM #fps_odbc_probe;")
    if(nrow(typed)!=1L || ncol(typed)!=3L ||
       !identical(as.character(typed[[1]]),"9007199254740993") ||
       !identical(enc2utf8(as.character(typed[[2]])),"\uD55C\uAE00") || !is.na(typed[[3]][1]))
        stop("Big integer, Korean text, or SQL NULL conversion failed")
    passed("typed-temp-table")
    again <- query("Same session","SELECT @@SPID AS sessionId;")
    if(nrow(again)!=1L || !identical(as.integer(again[[1]]),session)) stop("Physical session changed")
    passed("same-session")
    run("Temporary table drop",api$execute(connection,"DROP TABLE #fps_odbc_probe;"))
    passed("temp-cleanup")
    checks
}

fp_odbc_probe_disconnect <- function(connection,event,
        disconnect=DBI::dbDisconnect,valid=DBI::dbIsValid) {
    event("ODBC disconnect","started")
    if(!isTRUE(disconnect(connection))) stop("ODBC disconnect did not report success")
    event("ODBC disconnect","completed")
    event("Verify connection closed","started")
    if(!identical(valid(connection),FALSE)) stop("ODBC connection remains valid after disconnect")
    event("Verify connection closed","completed")
    invisible(TRUE)
}

# Classify without returning any substring except allowlisted field/code names.
# Raw driver messages may contain hostnames, usernames, SQL and secret values.
fp_odbc_probe_error <- function(error) {
    message <- conditionMessage(error)
    states <- c("28000","08001","08004","08S01","HYT00","HYT01","IM002","IM003","IM014","42000","42S02","42S22")
    matched <- states[vapply(states,function(code)grepl(paste0("(^|[^A-Za-z0-9])",code,"([^A-Za-z0-9]|$)"),message),TRUE)]
    native <- c("18456","18452","4060","10060","10061")
    native <- native[vapply(native,function(code)grepl(paste0("(^|[^0-9])",code,"([^0-9]|$)"),message),TRUE)]
    category <- "probe-failed"
    if(grepl("Missing/unloadable package|there is no package called|package or namespace load failed|Missing jsonlite",message,ignore.case=TRUE))category <- "r-dependency-missing"
    else if(grepl("ODBC driver is missing",message,fixed=TRUE) || any(matched %in% c("IM002","IM003","IM014")))category <- "odbc-driver-missing-or-architecture"
    else if(grepl("certificate|SSL Provider|TLS|certificate chain",message,ignore.case=TRUE))category <- "tls-certificate-or-protocol"
    else if(any(matched %in% c("HYT00","HYT01")))category <- "odbc-timeout"
    else if("28000" %in% matched || any(native %in% c("18456","18452")))category <- "authentication-rejected"
    else if(any(matched %in% c("08001","08004","08S01")) || any(native %in% c("10060","10061")))category <- "network-or-endpoint"
    else if("4060" %in% native)category <- "database-access-rejected"
    else if(any(matched %in% c("42000","42S02","42S22")))category <- "sql-permission-schema-or-syntax"
    else if(grepl("CARE_SITE must contain",message,fixed=TRUE))category <- "care-site-id-missing-or-duplicate"
    else if(grepl("conversion failed",message,fixed=TRUE))category <- "data-type-roundtrip-failed"
    else if(grepl("session changed",message,fixed=TRUE))category <- "physical-session-changed"
    else if(grepl("disconnect|remains valid|clear result",message,ignore.case=TRUE))category <- "resource-cleanup-failed"
    else if(grepl("Missing connection fields|YUHS settings|DB_SERVER|DB_DATABASE|CDM_DATABASE_SCHEMA|DBMS|Invalid database port|DB_ODBC_DRIVER|must be true or false|unsupported combination",message))category <- "connection-config-invalid"
    else if(grepl("lacks the|SQL rendering|loaded Java",message))category <- "runtime-or-sqlrender-invalid"
    fields <- c("DBMS","DB_SERVER","DB_PORT","DB_DATABASE","DB_USER","DB_PASSWORD","CDM_DATABASE_SCHEMA","DB_ODBC_DRIVER","DB_ENCRYPT","DB_TRUST_SERVER_CERTIFICATE")
    fields <- if(category=="connection-config-invalid")fields[vapply(fields,function(key)grepl(paste0("\\b",key,"\\b"),message),TRUE)] else character()
    list(category=category,sqlState=matched,nativeCode=native,configFields=fields)
}
