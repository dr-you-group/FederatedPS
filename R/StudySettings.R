#' Get the definition of a named study
#'
#' @param study Name from [listStudies()].
#' @param scenario `"default"` for the common first-recorded-use design or
#'   `"studySpecific"` for the study's indication, observation, washout and
#'   product restrictions.
#' @return A list describing the exposure and covariate definitions. Concept
#'   sets are resolved against each hospital's vocabulary by [getDbStudyData()].
#' @details Both scenarios require age 18 or older and a native observation
#'   period containing index. `default` uses the first recorded drug era,
#'   covariates on days -90 through -1, and no prior-observation or drug-free
#'   requirement. `studySpecific` uses the first eligible drug exposure and
#'   restricts clinical covariates and indications to before the linked acute
#'   episode as well as before index. The windows are benchmark design choices,
#'   not replications of the cited clinical studies. See the README for details.
#' @export
getStudySettings <- function(study = "opioid", scenario = c("default", "studySpecific")) {
    scenario <- match.arg(scenario)
    studies <- .studyDefinitions()
    if (length(study) != 1L || is.na(study) || !study %in% names(studies)) {
        stop("Unknown study; use listStudies() for available names")
    }
    settings <- c(list(study = study, scenario = scenario, definitionVersion = 1L,
                       minAge = 18L), studies[[study]])
    if (scenario == "default") {
        settings$priorObservationDays <- 0L
        settings$washoutDays <- 0L
        settings$washoutAtc <- character()
        settings$extraWashoutIngredients <- numeric()
        settings$indicationConceptIds <- numeric()
        settings$indicationDays <- 0L
        settings$formPolicy <- "all"
    }
    settings$longTermStartDays <- if (scenario == "default") -90L else -settings$priorObservationDays
    settings$shortTermStartDays <- if (scenario == "default") NULL else -30L
    settings$endDays <- -1L
    settings$excludeIndexEpisode <- scenario == "studySpecific"
    settings$recordTypeConceptIds <- if (scenario == "default") numeric() else
        c(32818, 32825, 32833, 32838, 32839, 38000175, 38000176, 38000177,
          38000179, 38000180, 581373, 581452, 38000275)
    settings
}

#' List available study presets
#'
#' @return A data frame with study names, target and comparator labels and an
#'   indicator for the twelve selected benchmark comparisons. `statin` retains
#'   the original example's drug pair as an additional reference.
#' @export
listStudies <- function() {
    studies <- .studyDefinitions()
    data.frame(study = names(studies),
               target = vapply(studies, `[[`, character(1), "target"),
               comparator = vapply(studies, `[[`, character(1), "comparator"),
               selected = names(studies) != "statin", row.names = NULL)
}

.studyDefinitions <- function() {
    opioidIngredients <- c(1110410, 1126658, 1154029, 1103314, 1201620,
                           1125765, 1103640, 1133201, 19026459, 1102527)
    study <- function(target, comparator, ingredients, prior, washout, indicationDays,
                      indicationConceptIds, washoutAtc, formPolicy = "oral_single",
                      extraWashoutIngredients = numeric()) {
        list(target = target, comparator = comparator,
             targetIngredients = ingredients[1], comparatorIngredients = ingredients[2],
             targetAtc = character(), comparatorAtc = character(),
             priorObservationDays = prior, washoutDays = washout,
             indicationDays = indicationDays, indicationConceptIds = indicationConceptIds,
             washoutAtc = washoutAtc, extraWashoutIngredients = extraWashoutIngredients,
             formPolicy = formPolicy)
    }
    studies <- list(
        opioid = study("oxycodone", "hydrocodone", c(1124957, 1174888),
            365, 365, 30, 4329041, "N02A", "oral_ir_opioid", opioidIngredients),
        oxycodone_hydromorphone = study("oxycodone", "hydromorphone", c(1124957, 1126658),
            365, 365, 30, 4329041, "N02A", "oral_ir_opioid", opioidIngredients),
        laxative = study("polyethylene glycol 3350", "sennosides, USP", c(986417, 938268),
            90, 30, 30, 75860, "A06A"),
        morphine_hydromorphone = study("morphine", "hydromorphone", c(1110410, 1126658),
            90, 30, 7, 4329041, "N02A", "parenteral_single", opioidIngredients),
        acid_suppression = study("pantoprazole", "famotidine", c(948078, 953076),
            180, 180, 180, 318800, c("A02BC", "A02BA")),
        class_ppi_h2ra = study("PPI", "H2RA", c(0, 0),
            180, 180, 180, 318800, c("A02BC", "A02BA")),
        ppi = study("pantoprazole", "omeprazole", c(948078, 923645),
            180, 180, 180, 318800, "A02BC"),
        acetaminophen_ibuprofen = study("acetaminophen", "ibuprofen", c(1125315, 1177480),
            90, 30, 30, c(4150129, 80180), c("N02BE01", "M01A")),
        antiemetic = study("ondansetron", "metoclopramide", c(1000560, 906780),
            90, 7, 7, c(31967, 441408), c("A04", "A03FA")),
        ondansetron_promethazine = study("ondansetron", "promethazine", c(1000560, 1153013),
            90, 7, 7, c(31967, 441408), c("A04", "A03FA"),
            "parenteral_single", c(752061, 1153013)),
        ondansetron_prochlorperazine = study("ondansetron", "prochlorperazine", c(1000560, 752061),
            90, 7, 7, c(31967, 441408), c("A04", "A03FA"),
            "parenteral_single", c(752061, 1153013)),
        pantoprazole_lansoprazole = study("pantoprazole", "lansoprazole", c(948078, 929887),
            180, 180, 180, 318800, "A02BC"),
        statin = study("atorvastatin", "simvastatin", c(1545958, 1539403),
            365, 365, 365, c(432867, 4029305), "C10AA")
    )
    studies$class_ppi_h2ra$targetIngredients <- numeric()
    studies$class_ppi_h2ra$comparatorIngredients <- numeric()
    studies$class_ppi_h2ra$targetAtc <- "A02BC"
    studies$class_ppi_h2ra$comparatorAtc <- "A02BA"
    studies
}
