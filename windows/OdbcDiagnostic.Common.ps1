#Requires -Version 5.1
# Process receipt validation is deliberately independent of console output.
function Wait-FederatedOdbcProbe {
    param([Diagnostics.Process]$Process,[string]$StatusPath,[string]$Token,
        [ValidateSet('native','production')][string]$Mode,[int[]]$SiteIds,
        [ValidateRange(1,900)][int]$TimeoutSeconds=180)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastPhase='';$nextReport=[DateTime]::UtcNow
    while($true){
        $Process.Refresh()
        if($Process.HasExited){break}
        if([DateTime]::UtcNow -ge $deadline){
            throw "ODBC $Mode probe exceeded ${TimeoutSeconds}s. Last recorded step: $lastPhase. This is a failed check, not a successful query timeout."
        }
        if([DateTime]::UtcNow -ge $nextReport){
            $nextReport=[DateTime]::UtcNow.AddSeconds(5)
            if(Test-Path -LiteralPath $StatusPath -PathType Leaf){
                try{
                    $snapshot=Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if($snapshot.token -ceq $Token -and $snapshot.pid -eq $Process.Id -and $snapshot.mode -ceq $Mode){
                        $lastPhase=[string]$snapshot.phase
                        Write-Host ("ODBC {0}: {1} [{2}]" -f $Mode,$lastPhase,$snapshot.phaseState)
                    }
                }catch{} # An in-flight JSON write is retried, never treated as success.
            }
        }
        Start-Sleep -Milliseconds 100
    }
    $Process.WaitForExit()
    if($Process.ExitCode -ne 0){throw "ODBC $Mode probe failed (exit $($Process.ExitCode)); inspect its sanitized status.json and events.ndjson."}
    if(-not(Test-Path -LiteralPath $StatusPath -PathType Leaf)){throw 'ODBC process exited without a completion receipt.'}
    $receipt=Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $expected=@('self-check')+@($SiteIds | ForEach-Object {'site-'+$_})+@('typed-temp-table','same-session','temp-cleanup','disconnect')
    if($receipt.token -cne $Token -or $receipt.pid -ne $Process.Id -or $receipt.mode -cne $Mode -or
       $receipt.state -cne 'checks-complete' -or $receipt.phase -cne 'R natural exit' -or
       (@($receipt.checks)-join ',') -cne ($expected-join ',')){
        throw 'ODBC process exited with an incomplete or mismatched completion receipt.'
    }
    [pscustomobject]@{mode=$Mode;state='passed';pid=$Process.Id;exitCode=$Process.ExitCode;
        naturalExit=$true;checks=@($receipt.checks)}
}
