#' Publish versioned public-study definitions to a local OHDSI WebAPI
#'
#' @param baseUrl WebAPI URL, e.g. `http://localhost:18080/WebAPI`.
#' @param studies Public IDs; NULL publishes all public candidates.
#' @param scenarios Scenarios to publish.
#' @param outputFile Optional local CSV mapping registry IDs to ATLAS IDs.
#' @return Data frame of study/scenario/arm, cohort ID, name and definition hash.
#' @details Publishes definitions only. No patients or counts are uploaded and no
#'   cohort generation is requested. Hash-suffixed names permit repeat runs and
#'   preserve existing versions. Also publishes standalone concept sets so they
#'   can be inspected using ATLAS's concept-set interface. Never overwrites an
#'   existing definition. Use a dedicated local instance without manual edits to
#'   these generated objects. Legacy R/SQL presets are not converted implicitly.
#' @export
publishStudyDefinitions <- function(baseUrl, studies = NULL,
                                    scenarios = c("default", "studySpecific"),
                                    outputFile = NULL) {
    .requireStudyPackages(atlas = TRUE)
    if (is.null(studies)) studies <- names(.publicStudyDefinitions())
    cohorts <- ROhdsiWebApi::getCohortDefinitionsMetaData(baseUrl)
    concepts <- ROhdsiWebApi::getConceptSetDefinitionsMetaData(baseUrl)
    rows <- list()
    for (study in studies) for (scenario in scenarios) {
        defs <- getStudyCohortDefinitions(study, scenario)
        for (i in seq_len(nrow(defs))) {
            name <- paste(defs$cohortName[i], substr(defs$definitionHash[i], 1, 12), sep = " / ")
            expression <- jsonlite::fromJSON(defs$json[i], simplifyVector = FALSE)
            found <- if (nrow(cohorts)) cohorts[cohorts$name == name, , drop = FALSE] else data.frame()
            if (!nrow(found)) {
                found <- ROhdsiWebApi::postCohortDefinition(name, expression, baseUrl)
                cohorts <- ROhdsiWebApi::getCohortDefinitionsMetaData(baseUrl)
            }
            id <- if ("cohortId" %in% names(found)) found$cohortId[1] else found$id[1]
            # Always fetch the stored expression; server normalization is allowed,
            # but executable SQL must agree with the bundled execution definition.
            remote <- ROhdsiWebApi::getCohortDefinition(id, baseUrl)
            # Preserve named RJSONIO vectors and full integer precision. The
            # deprecated expression helper rounds large concept IDs on export.
            remoteJson <- RJSONIO::toJSON(remote$expression, digits = 23)
            remoteSql <- CirceR::buildCohortQuery(CirceR::cohortExpressionFromJson(remoteJson),
                                                CirceR::createGenerateOptions(generateStats = TRUE))
            if (!identical(remoteSql, defs$sql[i])) stop("Stored ATLAS definition differs: ", name)
            conceptErrors <- character()
            for (set in expression$ConceptSets) {
                set$expression$items <- lapply(set$expression$items, function(item) {
                    for (field in c("isExcluded", "includeDescendants", "includeMapped")) {
                        if (is.null(item[[field]])) item[[field]] <- FALSE
                    }
                    item
                })
                definition <- jsonlite::toJSON(set$expression, auto_unbox = TRUE, null = "null")
                hash <- digest::digest(definition, algo = "sha256", serialize = FALSE)
                csName <- paste("FPS", set$name, substr(hash, 1, 12), sep = " / ")
                if (!nrow(concepts) || !csName %in% concepts$name) {
                    ROhdsiWebApi::postConceptSetDefinition(csName, set$expression, baseUrl)
                    concepts <- ROhdsiWebApi::getConceptSetDefinitionsMetaData(baseUrl)
                }
                csId <- concepts$id[match(csName, concepts$name)]
                tryCatch({
                    stored <- ROhdsiWebApi::getConceptSetDefinition(csId, baseUrl)
                    storedJson <- RJSONIO::toJSON(stored$expression, digits = 23)
                    if (!identical(CirceR::buildConceptSetQuery(as.character(definition)),
                                   CirceR::buildConceptSetQuery(storedJson))) stop("Concept-set SQL differs")
                }, error = function(e) {
                    conceptErrors <<- c(conceptErrors, paste(csName, conditionMessage(e), sep = ": "))
                    warning("Concept set requires vocabulary review: ", csName, call. = FALSE)
                })
            }
            rows[[length(rows)+1L]] <- data.frame(study = study, scenario = scenario,
                arm = c("target", "comparator")[i], registryCohortId = defs$cohortId[i],
                atlasCohortId = id, name = name, definitionHash = defs$definitionHash[i],
                conceptReview = paste(conceptErrors, collapse = "; "))
            if (!is.null(outputFile)) utils::write.csv(do.call(rbind, rows), outputFile, row.names = FALSE)
        }
    }
    do.call(rbind, rows)
}
