#Requires -Version 5.1
[CmdletBinding()]
param([string]$Project='',[string]$InstallRoot='C:\FederatedPS',
    [string]$RHome='C:\Program Files\R\R-4.6.1',[string]$JavaHome='',
    [string]$ConfigDirectory='',[int[]]$SiteIds=@(),
    [ValidateSet('both','native','production')][string]$Mode='both',
    [ValidateRange(1,300)][int]$LoginTimeoutSeconds=30,
    [ValidateRange(15,900)][int]$TimeoutSeconds=180,[string]$OutputDirectory='')
$ErrorActionPreference='Stop'
if(-not $Project){$Project=Join-Path $PSScriptRoot '..'}
$Project=(Resolve-Path -LiteralPath $Project).Path
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'OdbcDiagnostic.Common.ps1')
if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'Use 64-bit Windows PowerShell on the Windows instance.'}
if(-not $ConfigDirectory){$ConfigDirectory=Join-Path $Project 'windows\config'}
$settings=Join-Path ([IO.Path]::GetFullPath($ConfigDirectory)) 'yuhs.Renviron'
if(-not(Test-Path -LiteralPath $settings -PathType Leaf)){throw 'Existing yuhs.Renviron not found. Configure the same authorized HIWARE endpoint first.'}
$rscript=Join-Path $RHome 'bin\x64\Rscript.exe'
$base=Join-Path $InstallRoot 'RLibrary\4.6';$overlay=Join-Path $InstallRoot 'RLibrary\windows-block'
foreach($required in @($rscript,$base,$overlay)){
    if(-not(Test-Path -LiteralPath $required)){throw "Offline prerequisite missing: $required"}
}
# Native phase deliberately needs no Java or JDBC path. Production phase later
# uses the normal JVM for SqlRender, while all DB I/O remains native ODBC.
$env:R_LIBS_USER="$overlay;$base";$env:R_LIBS=$env:R_LIBS_USER
$env:FEDERATEDPS_LIBRARY=$overlay;$env:FEDERATEDPS_PROJECT=$Project
if(-not $SiteIds.Count){
    $mapping=Join-Path $ConfigDirectory 'yuhs-sites.json'
    if(-not(Test-Path -LiteralPath $mapping -PathType Leaf)){$mapping=Join-Path $Project 'windows\config\yuhs-sites.json'}
    $sites=Get-Content -LiteralPath $mapping -Raw -Encoding UTF8 | ConvertFrom-Json
    $SiteIds=@($sites.PSObject.Properties | ForEach-Object {
        $id=0L
        if(-not [long]::TryParse([string]$_.Value,[ref]$id) -or $id -lt 1 -or $id -gt 2147483647){throw 'Invalid configured CARE_SITE_ID.'}
        [int]$id
    } | Sort-Object)
}
if(-not $SiteIds.Count -or @($SiteIds | Where-Object {$_ -lt 1}).Count -or
   @($SiteIds | Sort-Object -Unique).Count -ne $SiteIds.Count){throw 'Provide distinct positive SiteIds.'}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $Project 'work\diagnostics'}
$out=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ('odbc-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $out -Force | Out-Null
$modes=if($Mode -eq 'both'){@('native','production')}else{@($Mode)}
$results=@();$failure=$null
Write-Host "ODBC checks: $($modes -join ', '); site_ids=$($SiteIds -join ','). Logs: $out"
Write-Host 'Login timeout bounds connection establishment only; the parent separately bounds each complete probe and process exit.'
try{
    foreach($phase in $modes){
        if($phase -eq 'production'){
            $runtime=Set-FederatedEnvironment -InstallRoot $InstallRoot -RHome $RHome -JavaHome $JavaHome
            $rscript=$runtime.Rscript
        }
        $phaseOut=Join-Path $out $phase;New-Item -ItemType Directory -Path $phaseOut | Out-Null
        $token=[guid]::NewGuid().ToString('N')
        $p=New-Object Diagnostics.Process
        $stdoutTask=$null;$stderrTask=$null;$started=$false;$forced=$false
        $begin=[DateTime]::UtcNow
        try{
            $p.StartInfo=New-Object Diagnostics.ProcessStartInfo
            $p.StartInfo.FileName=$rscript
            $arguments=@('--vanilla',(Join-Path $PSScriptRoot 'check-odbc.R'),$Project,$settings,$phase,$phaseOut,$token,($SiteIds -join ','),[string]$LoginTimeoutSeconds)
            $p.StartInfo.Arguments=(($arguments | ForEach-Object {ConvertTo-NativeArgument $_}) -join ' ')
            $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true
            $p.StartInfo.WorkingDirectory=$Project
            $p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
            $p.StartInfo.EnvironmentVariables['R_DEFAULT_PACKAGES']='utils,stats,methods'
            $p.StartInfo.EnvironmentVariables['FEDERATEDPS_DB_BACKEND']='odbc'
            $started=$p.Start()
            if(-not $started){throw 'Could not start the owned ODBC probe.'}
            # Keep raw streams private: rejected Renviron lines or native driver
            # errors can contain secrets. Only fixed labels reach diagnostic files.
            $stdoutTask=$p.StandardOutput.ReadToEndAsync();$stderrTask=$p.StandardError.ReadToEndAsync()
            $result=Wait-FederatedOdbcProbe -Process $p -StatusPath (Join-Path $phaseOut 'status.json') `
                -Token $token -Mode $phase -SiteIds $SiteIds -TimeoutSeconds $TimeoutSeconds
            if(-not $stdoutTask.Wait(2000) -or -not $stderrTask.Wait(2000)){throw 'ODBC probe exited but private stream drain did not complete.'}
            $results+=,$result
            Write-Host "PASS: ODBC $phase checks, explicit disconnect and natural R exit." -ForegroundColor Green
        }finally{
            if($started){
                $p.Refresh()
                if(-not $p.HasExited){$forced=$true;Stop-FederatedProcessTree $p}
                $receipt=[ordered]@{mode=$phase;pid=$p.Id;elapsedSeconds=([DateTime]::UtcNow-$begin).TotalSeconds;
                    forcedTermination=$forced;exitCode=$(if($p.HasExited){$p.ExitCode}else{$null});
                    rawStreamsSaved=$false}
                [IO.File]::WriteAllText((Join-Path $phaseOut 'process.json'),($receipt | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
                foreach($task in @($stdoutTask,$stderrTask)){if($null -ne $task){try{[void]$task.Wait(2000)}catch{}}}
            }
            $p.Dispose()
        }
    }
}catch{
    $failure=$_.Exception.Message
    throw
}finally{
    $summary=[ordered]@{state=$(if($failure){'failed'}else{'passed'});modes=$modes;results=$results;failure=$failure;
        scope='Connection, configured CARE_SITE IDs, synthetic temporary table, data types, disconnect and natural process exit. No clinical cohort validation.'}
    [IO.File]::WriteAllText((Join-Path $out 'summary.json'),($summary | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
}
Write-Host "PASS: ODBC preflight complete. Diagnostic directory: $out" -ForegroundColor Green
