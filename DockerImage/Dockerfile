ARG BASE_IMAGE=rocker/rstudio:4.6.1@sha256:530406cfa1fa6af692e41f15bd3f63170939919c6dea11d4de3364aa51d8f357
FROM ${BASE_IMAGE}

ENV MAKEFLAGS=-j2
ENV JAVA_HOME=/usr/lib/jvm/default-java
ENV OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
ENV DUCKDB_R_HOME=/tmp/duckdb-r
RUN apt-get update && apt-get install -y --no-install-recommends \
    default-jdk libcurl4-openssl-dev libssl-dev libxml2-dev libgit2-dev \
    libfontconfig1-dev libfreetype6-dev libpng-dev libtiff-dev libjpeg-dev \
    libharfbuzz-dev libfribidi-dev libglpk-dev libuv1-dev xz-utils && \
    rm -rf /var/lib/apt/lists/* && R CMD javareconf

COPY DESCRIPTION /opt/FederatedPs/DESCRIPTION
RUN Rscript -e 'install.packages(c("remotes", "testthat", "roxygen2"), Ncpus=2); remotes::install_github(read.dcf("/opt/FederatedPs/DESCRIPTION")[1, "Remotes"], upgrade="never"); remotes::install_deps("/opt/FederatedPs", dependencies=NA, upgrade="never")'
ENV DATABASECONNECTOR_JAR_FOLDER=/opt/federatedps-drivers
RUN Rscript -e 'DatabaseConnector::downloadJdbcDrivers("postgresql", pathToDriver=Sys.getenv("DATABASECONNECTOR_JAR_FOLDER"))'
COPY NAMESPACE /opt/FederatedPs/NAMESPACE
COPY R /opt/FederatedPs/R
COPY man /opt/FederatedPs/man
RUN R CMD INSTALL /opt/FederatedPs
RUN cp -r /opt/FederatedPs /home/rstudio/FederatedPs && chown -R rstudio:rstudio /home/rstudio/FederatedPs
COPY --chown=rstudio:rstudio extras /home/rstudio/FederatedPs/extras
COPY --chown=rstudio:rstudio FederatedPs.Rproj README.md /home/rstudio/FederatedPs/
WORKDIR /home/rstudio/FederatedPs
