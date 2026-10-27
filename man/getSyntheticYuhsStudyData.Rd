\name{getSyntheticYuhsStudyData}
\alias{getSyntheticYuhsStudyData}
\title{Load a database-free three-institution YUHS-shaped sample}
\usage{
getSyntheticYuhsStudyData(careSiteId, study = "ppi", scenario = "default")
}
\arguments{
\item{careSiteId}{One of 1 (Severance), 2 (Gangnam), 3 (Yongin).}
\item{study, scenario}{Only \code{ppi} / \code{default} is supported by this fixture.}
}
\value{A local \code{CohortMethodData} for \code{fitPs()}. Close with \code{Andromeda::close()}.}
\description{Reads bundled invented CSV tables, partitions by visit/care site and prepares binary covariates in R. No connection settings or database are accessed.}
\details{Tests the package pipeline, not SQL Server, HIWARE, full OMOP validation or clinical validity. Feature metadata prevents mixing with real data. See \code{inst/extdata/yuhs-synthetic/README.md}.}
