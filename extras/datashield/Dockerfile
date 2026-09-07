ARG FEDERATEDPS_DEPENDENCY_IMAGE=federatedps-d-followup:zx3yuuwy
FROM obiba/rock:2.2.1-R4.6.1@sha256:16ddfcb9efeda78d9731c4252651345e2ac33bb681d5b7a15e11c6545da07939 AS native

LABEL org.federatedps.stage="C1"
ENV R_LIBS=/opt/federatedps/library
ENV MAKEFLAGS=-j2
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-21-jdk-headless && \
    rm -rf /var/lib/apt/lists/* && R CMD javareconf && \
    mkdir -p /opt/federatedps/library /opt/federatedps/reference-library
RUN Rscript --vanilla -e 'install.packages(c("RcppEigen", "Andromeda", "DSI", "DSOpal"), repos="https://cloud.r-project.org", lib=Sys.getenv("R_LIBS"), Ncpus=2)'

# The image's original JAVA_HOME points to a JRE without JNI headers.
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
RUN R CMD javareconf

# The build context contains only these source archives, never the workspace.
COPY Cyclops-reference.tar.gz Cyclops-patched.tar.gz /opt/federatedps/sources/
RUN R CMD INSTALL --library=/opt/federatedps/reference-library /opt/federatedps/sources/Cyclops-reference.tar.gz && \
    R CMD INSTALL --library=/opt/federatedps/library /opt/federatedps/sources/Cyclops-patched.tar.gz
RUN Rscript --vanilla -e 'install.packages("CohortMethod", repos="https://cloud.r-project.org", lib=Sys.getenv("R_LIBS"), Ncpus=2); stopifnot(packageVersion("CohortMethod") == "6.0.3", packageVersion("DSI") == "1.8.0", packageVersion("DSOpal") == "1.5.0", packageVersion("opalr") == "3.6.1")'
COPY FederatedPs.tar.gz /opt/federatedps/sources/
RUN R CMD INSTALL --library=/opt/federatedps/library /opt/federatedps/sources/FederatedPs.tar.gz

# Reuse a verified U/L/F dependency image; this target updates only R source.
FROM ${FEDERATEDPS_DEPENDENCY_IMAGE} AS package-update
COPY FederatedPs.tar.gz /opt/federatedps/sources/FederatedPs.tar.gz
RUN R CMD INSTALL --library=/opt/federatedps/library /opt/federatedps/sources/FederatedPs.tar.gz
