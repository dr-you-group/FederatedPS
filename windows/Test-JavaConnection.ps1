#Requires -Version 5.1
<# A read-only comparison in a standalone JVM, outside R/rJava. #>
[CmdletBinding()]
param([string]$Project='', [string]$InstallRoot='C:\FederatedPS',
      [string]$RHome='C:\Program Files\R\R-4.6.1', [string]$JavaHome='',
      [string]$ConfigDirectory='', [int[]]$SiteIds=@(),
      [ValidateRange(1,300)][int]$SmallQueryTimeoutSeconds=60,
      [ValidateRange(15,900)][int]$TimeoutSeconds=180,
      [ValidateSet('full','adaptive')][string]$ResponseBuffering='full',
      [ValidateSet('care-site-id','care-site-text','synthetic-text')][string]$ProbeMode='care-site-id',
      [string]$OutputDirectory='')
$ErrorActionPreference='Stop'
if (-not $Project) { $Project=Join-Path $PSScriptRoot '..' }
$Project=(Resolve-Path -LiteralPath $Project).Path
. (Join-Path $Project 'windows\Common.ps1')
$runtime=Set-FederatedEnvironment -InstallRoot $InstallRoot -RHome $RHome -JavaHome $JavaHome
if (-not $ConfigDirectory) { $ConfigDirectory=Join-Path $Project 'windows\config' }
$settings=Join-Path $ConfigDirectory 'yuhs.Renviron'
if (-not(Test-Path -LiteralPath $settings -PathType Leaf)) { throw 'Missing yuhs.Renviron.' }
if (-not $SiteIds.Count) {
    $mapping=Join-Path $ConfigDirectory 'yuhs-sites.json'
    if (-not(Test-Path -LiteralPath $mapping -PathType Leaf)) { $mapping=Join-Path $Project 'windows\config\yuhs-sites.json' }
    $sites=Get-Content -LiteralPath $mapping -Raw -Encoding UTF8 | ConvertFrom-Json
    $SiteIds=@($sites.PSObject.Properties | ForEach-Object {
        $id=0L
        if (-not [long]::TryParse([string]$_.Value,[ref]$id) -or $id -lt 1 -or $id -gt 2147483647) {
            throw 'Invalid CARE_SITE_ID in yuhs-sites.json.'
        }
        [int]$id
    } | Sort-Object)
}
if (-not $SiteIds.Count -or @($SiteIds | Where-Object {$_ -lt 1}).Count -or
    @($SiteIds | Sort-Object -Unique).Count -ne $SiteIds.Count) { throw 'Provide distinct positive SiteIds.' }
if (-not $OutputDirectory) { $OutputDirectory=Join-Path $Project 'work\diagnostics' }
$name='java-connection-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$out=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) $name
New-Item -ItemType Directory -Path $out -Force | Out-Null
$source=Join-Path $PSScriptRoot 'JdbcConnectionProbe.java'
$classDirectory=Join-Path $PSScriptRoot 'java11'
$compiledClass=Join-Path $classDirectory 'JdbcConnectionProbe.class'
$launchMode=if(Test-Path -LiteralPath $compiledClass -PathType Leaf){'compiled-java11'}else{'source'}
$exportScript=Join-Path $PSScriptRoot 'java-probe-config.R'
$java=Join-Path $env:JAVA_HOME 'bin\java.exe'
$program=if($launchMode -eq 'compiled-java11'){$compiledClass}else{$source}
foreach($required in @($program,$exportScript,$java)) {
    if (-not(Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing diagnostic dependency: $required" }
}
$state='failed';$exitCode=$null;$failure=$null;$jar=$null
$checksComplete=$false;$processExited=$false;$forcedTermination=$false;$outputDrained=$false
$terminationRequested=$false;$snapshotStarted=$false;$snapshotFinished=$false
$completionMarker='CHECKS_COMPLETE: independent Java checks and explicit close finished; waiting for process exit'
$export=$null;$process=$null;$stdoutFile=$null;$stderrFile=$null
$stdoutTask=$null;$stderrTask=$null;$privatePacket=$null;$privateLines=$null
$processSamples=New-Object 'System.Collections.Generic.List[object]'
$started=[DateTime]::UtcNow
try {
    # Base R reads .Renviron with its own parser. No rJava is loaded. Never save
    # stdout/stderr here: parser diagnostics can include a rejected secret line.
    $export=New-Object Diagnostics.Process
    $export.StartInfo=New-Object Diagnostics.ProcessStartInfo
    $export.StartInfo.FileName=$runtime.Rscript
    $export.StartInfo.Arguments=((@('--vanilla',$exportScript,$Project,[IO.Path]::GetFullPath($settings)) |
        ForEach-Object {ConvertTo-NativeArgument $_}) -join ' ')
    $export.StartInfo.UseShellExecute=$false;$export.StartInfo.CreateNoWindow=$true
    $export.StartInfo.RedirectStandardOutput=$true;$export.StartInfo.RedirectStandardError=$true
    $export.StartInfo.EnvironmentVariables['R_DEFAULT_PACKAGES']='utils,stats,methods'
    if (-not $export.Start()) { throw 'Could not start the private configuration reader.' }
    $privateOutput=$export.StandardOutput.ReadToEndAsync()
    $privateError=$export.StandardError.ReadToEndAsync()
    if (-not $export.WaitForExit(30000)) {
        Stop-FederatedProcessTree $export
        throw 'Private configuration reader exceeded 30 seconds; no DB connection was opened.'
    }
    if (-not $privateOutput.Wait(2000) -or -not $privateError.Wait(2000) -or $export.ExitCode -ne 0) {
        throw 'Configuration export failed. Check yuhs.Renviron and the JDBC path; private parser output was not saved.'
    }
    $privatePacket=$privateOutput.GetAwaiter().GetResult()
    $privateLines=@($privatePacket.TrimEnd("`r","`n") -split '\r?\n')
    if ($privateLines.Count -ne 10 -or $privateLines[0] -cne 'FPS_JAVA_PROBE_V1') { throw 'Invalid private configuration packet.' }
    foreach($line in $privateLines[1..9]) {
        if ($line.Length -gt 131072 -or $line.Length % 2 -ne 0 -or $line -cnotmatch '^[0-9a-f]+$') {
            throw 'Invalid private configuration field.'
        }
    }
    $pathBytes=New-Object byte[] ($privateLines[1].Length/2)
    for($i=0;$i -lt $pathBytes.Length;$i++) { $pathBytes[$i]=[Convert]::ToByte($privateLines[1].Substring(2*$i,2),16) }
    $jar=[Text.Encoding]::UTF8.GetString($pathBytes)
    if (-not(Test-Path -LiteralPath $jar -PathType Leaf)) { throw 'The selected JDBC JAR does not exist.' }
    Write-Host "Independent Java probe: $(Split-Path $jar -Leaf); launch=$launchMode; mode=$ProbeMode; site_ids=$($SiteIds -join ','); buffering=$ResponseBuffering."
    Write-Host "Logs: $out"
    $process=New-Object Diagnostics.Process
    $process.StartInfo=New-Object Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName=$java
    if($launchMode -eq 'compiled-java11'){
        # Precompiled Java 11 bytecode runs in a JRE without jdk.compiler.
        # The selected database JAR stays unchanged and is still verified by
        # the probe against the actual loaded driver class source.
        $classPath=@($jar,$classDirectory) -join [IO.Path]::PathSeparator
        $arguments=@('--class-path',$classPath,'JdbcConnectionProbe')
    }else{$arguments=@('--class-path',$jar,$source)}
    $arguments+=@([string]$SmallQueryTimeoutSeconds,[string]$TimeoutSeconds,
        $ResponseBuffering,($SiteIds -join ','),$ProbeMode)
    $process.StartInfo.Arguments=(($arguments | ForEach-Object {ConvertTo-NativeArgument $_}) -join ' ')
    $process.StartInfo.WorkingDirectory=$Project
    $process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardInput=$true
    $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
    $stdoutFile=New-Object IO.FileStream((Join-Path $out 'java.stdout.log'),[IO.FileMode]::Create,
        [IO.FileAccess]::Write,[IO.FileShare]::Read,1)
    $stderrFile=New-Object IO.FileStream((Join-Path $out 'java.stderr.log'),[IO.FileMode]::Create,
        [IO.FileAccess]::Write,[IO.FileShare]::Read,1)
    if (-not $process.Start()) { throw 'Could not start the independent Java probe.' }
    $stdoutTask=$process.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
    $stderrTask=$process.StandardError.BaseStream.CopyToAsync($stderrFile)
    # Only stdin carries the captured fields. No secret appears in the command,
    # environment additions, temporary credential files, or exported ZIP.
    $inputWrite=$process.StandardInput.WriteAsync($privatePacket)
    if (-not $inputWrite.Wait(10000)) { throw 'Timed out handing private input to Java.' }
    $inputFlush=$process.StandardInput.FlushAsync()
    if (-not $inputFlush.Wait(10000)) { throw 'Timed out flushing private input to Java.' }
    $process.StandardInput.Close()
    $privatePacket=$null;$privateLines=$null;$privateOutput=$null;$privateError=$null
    $javaStarted=[DateTime]::UtcNow;$lastStatus=$javaStarted.AddSeconds(-10)
    $outerLimit=$TimeoutSeconds+15 # covers process launch/optional source compilation/shutdown
    while (-not $process.WaitForExit(200)) {
        $now=[DateTime]::UtcNow
        if (($now-$lastStatus).TotalSeconds -ge 10) {
            try {
                $process.Refresh()
                $cpu=$process.TotalProcessorTime;$threads=$process.Threads;$workingSet=$process.WorkingSet64
                $processSamples.Add([ordered]@{elapsedSeconds=[Math]::Round(($now-$javaStarted).TotalSeconds,1);
                    cpuSeconds=if($null -ne $cpu){[Math]::Round($cpu.TotalSeconds,3)}else{$null};
                    threads=if($null -ne $threads){$threads.Count}else{$null};workingSetBytes=$workingSet})
            } catch { }
            $last=@(Get-Content -LiteralPath (Join-Path $out 'java.stdout.log') -Tail 1 -Encoding UTF8 -ErrorAction SilentlyContinue)
            Write-Host ("Java probe: {0}s / {1}s outer limit; {2}" -f [Math]::Floor(($now-$javaStarted).TotalSeconds),$outerLimit,($last -join ''))
            $lastStatus=$now
        }
        if (($now-$javaStarted).TotalSeconds -ge $outerLimit) {
            $process.Refresh()
            if ($process.HasExited) { break }
            $state='timeout';$forcedTermination=$true
            Stop-FederatedProcessTree $process
            throw "Independent Java process exceeded ${outerLimit}s; only this probe process was stopped."
        }
    }
    $exitCode=$process.ExitCode
    if (-not $stdoutTask.Wait(2000) -or -not $stderrTask.Wait(2000)) { throw 'Java output streams did not finish.' }
    $stdoutFile.Flush();$stderrFile.Flush()
    if ($exitCode -eq 124) { $state='timeout';throw 'Java watchdog detected a stalled call; see its phase and thread dump.' }
    $checksComplete=Select-String -LiteralPath (Join-Path $out 'java.stdout.log') -Pattern ('^\S+ '+[regex]::Escape($completionMarker)+'$') -Quiet
    if ($exitCode -ne 0 -or -not $checksComplete) { throw "Independent Java probe failed (exit $exitCode). See java.stdout.log and java.stderr.log." }
    $state='passed'
} catch {
    $failure=$_.Exception.Message
} finally {
    $privatePacket=$null;$privateLines=$null;$privateOutput=$null;$privateError=$null
    foreach($owned in @($process,$export)) {
        if ($null -ne $owned) {
            try {
                $owned.Refresh()
                if(-not $owned.HasExited){
                    if ([object]::ReferenceEquals($owned,$process)) { $forcedTermination=$true }
                    Stop-FederatedProcessTree $owned
                }
            } catch { }
        }
    }
    $outputDrained=($null -ne $stdoutTask -and $null -ne $stderrTask)
    foreach($task in @($stdoutTask,$stderrTask)) {
        if($null -ne $task){
            try {
                if(-not $task.Wait(2000)){$outputDrained=$false}
                elseif($task.IsFaulted -or $task.IsCanceled){$outputDrained=$false}
            }catch{$outputDrained=$false}
        }
    }
    foreach($stream in @($stdoutFile,$stderrFile)) { if($null -ne $stream){$stream.Dispose()} }
    if($null -ne $process){
        try {
            $process.Refresh();$processExited=$process.HasExited
            if($processExited){$exitCode=$process.ExitCode}
        }catch{ }
    }
    foreach($owned in @($process,$export)) { if($null -ne $owned){$owned.Dispose()} }
}
# Only inspect aggregate completion after the private process's output has
# drained. A partial log line or a pending CopyToAsync must not certify checks.
if($outputDrained){
    $checksComplete=Select-String -LiteralPath (Join-Path $out 'java.stdout.log') -Pattern ('^\S+ '+[regex]::Escape($completionMarker)+'$') -Quiet
    $terminationRequested=Select-String -LiteralPath (Join-Path $out 'java.stdout.log') -Pattern '^\S+ START JVM termination System\.exit\(-?[0-9]+\)$' -Quiet
    $snapshotStarted=(Select-String -LiteralPath (Join-Path $out 'java.stdout.log') -Pattern '^\S+ JAVA_PRE_EXIT_THREAD_DUMP_BEGIN$' -Quiet) -or
        (Select-String -LiteralPath (Join-Path $out 'java.stderr.log') -Pattern '^JAVA_PRE_EXIT_THREAD_DUMP_BEGIN_RAW$' -Quiet)
    $snapshotFinished=(Select-String -LiteralPath (Join-Path $out 'java.stdout.log') -Pattern '^\S+ JAVA_PRE_EXIT_THREAD_DUMP_END$' -Quiet) -or
        (Select-String -LiteralPath (Join-Path $out 'java.stderr.log') -Pattern '^JAVA_PRE_EXIT_THREAD_DUMP_END_RAW$' -Quiet)
}
if($state -eq 'timeout' -and $checksComplete){
    if($terminationRequested){
        $state='shutdown-timeout'
        $failure='Database checks and explicit disconnect completed, but the Java process did not exit within the configured deadline. This is a process shutdown failure, not a query timeout.'
    }else{
        $state='post-check-timeout'
        $failure='Database checks and explicit disconnect completed, but the probe stalled before a JVM termination request was recorded. Inspect the pre-exit snapshot markers; this is not a query timeout and does not prove shutdown had started.'
    }
}
if($state -eq 'passed' -and (-not $checksComplete -or -not $processExited -or $forcedTermination -or $exitCode -ne 0 -or -not $outputDrained)){
    $state='failed';$failure='Could not verify completed checks, normal process exit and drained output.'
}
if($failure){Write-Warning $failure}
$receipt=[ordered]@{state=$state;independentJvm=$true;driverFile=if($jar){Split-Path $jar -Leaf}else{$null};
    javaExecutable=[IO.Path]::GetFullPath($java);launchMode=$launchMode;checksComplete=[bool]$checksComplete;processExited=$processExited;
    terminationRequested=[bool]$terminationRequested;snapshotStarted=[bool]$snapshotStarted;snapshotFinished=[bool]$snapshotFinished;
    normalExitObserved=[bool]($processExited -and -not $forcedTermination -and $exitCode -eq 0);
    forcedTermination=$forcedTermination;outputDrained=$outputDrained;
    sites=@($SiteIds);probeMode=$ProbeMode;responseBuffering=$ResponseBuffering;smallQueryTimeout=$SmallQueryTimeoutSeconds;
    totalTimeout=$TimeoutSeconds;exitCode=$exitCode;elapsedSeconds=[Math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,3);
    failure=$failure;processSamples=@($processSamples.ToArray());
    scope=if($ProbeMode -eq 'synthetic-text'){'SELECT 1 and fixed synthetic strings only; no CDM rows'}else{'SELECT 1 and bounded CARE_SITE queries only; no cohort extraction'}}
$receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding UTF8
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=$out+'.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($out,$zip,[IO.Compression.CompressionLevel]::Optimal,$true)
Write-Host "Diagnostic ZIP: $zip"
if ($state -eq 'passed') {
    Write-Host "PASS: independent Java $ProbeMode checks, explicit disconnect and process exit." -ForegroundColor Green
    Write-Host 'This result does not certify the R/rJava path or cohort extraction.'
} else { throw "Independent Java diagnostic $state. Share the diagnostic ZIP shown above." }
