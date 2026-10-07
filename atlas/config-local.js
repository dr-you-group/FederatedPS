define([], function () {
    var url = window.location.protocol + "//" + window.location.hostname + ":18080/WebAPI/";
    return {
        webAPIRoot: url,
        api: {name: "FederatedPS study definitions", url: url},
        userAuthenticationEnabled: false,
        useExecutionEngine: false,
        cohortComparisonResultsEnabled: false,
        plpResultsEnabled: false,
        cacheSources: false,
        enablePersonCount: false
    };
});
