#Requires -Version 5.1
<# Standalone JDK baseline. Does not load R, a JDBC JAR or database settings. #>
[CmdletBinding()]
param([string]$BundleRoot='C:\FP', [string]$JavaHome='',
      [ValidateRange(5,120)][int]$TimeoutSeconds=30,
      [string]$OutputDirectory='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function ConvertTo-JvmProbeArgument([AllowEmptyString()][string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Stop-OwnedJvmProbe([Diagnostics.Process]$Process) {
    $Process.Refresh()
    if ($Process.HasExited) { return $false }
    $killed=$false
    try { $Process.Kill(); $killed=$true }
    catch { $Process.Refresh(); if(-not $Process.HasExited){throw} }
    if (-not $Process.WaitForExit(2000)) { throw 'Owned diagnostic process did not exit after termination.' }
    return $killed
}

function Get-JvmProbeSample([Diagnostics.Process]$Process, [Diagnostics.Stopwatch]$Clock) {
    $sample=[ordered]@{elapsedSeconds=[Math]::Round($Clock.Elapsed.TotalSeconds,3);
        utc=[DateTime]::UtcNow.ToString('o');cpuSeconds=$null;workingSetBytes=$null;threads=@();sampleError=$null}
    try {
        $Process.Refresh()
        if ($Process.HasExited) { return [pscustomobject]$sample }
        try {
            $cpu=$Process.TotalProcessorTime
            if($null -ne $cpu){$sample.cpuSeconds=[Math]::Round($cpu.TotalSeconds,3)}
        } catch { }
        try {$sample.workingSetBytes=$Process.WorkingSet64} catch { }
        $threadSamples=New-Object 'System.Collections.Generic.List[object]'
        foreach ($thread in @($Process.Threads | Select-Object -First 128)) {
            try {
                $state=[string]$thread.ThreadState
                $wait=$null
                if ($state -eq 'Wait') { try{$wait=[string]$thread.WaitReason}catch{} }
                $threadSamples.Add([ordered]@{id=$thread.Id;state=$state;waitReason=$wait})
            } catch { }
        }
        $sample.threads=@($threadSamples.ToArray())
    } catch { $sample.sampleError=$_.Exception.Message }
    [pscustomobject]$sample
}

function Get-JvmProbeThreads([Diagnostics.Process]$Target, [string]$Jcmd, [string]$Directory) {
    $result=[ordered]@{available=(Test-Path -LiteralPath $Jcmd -PathType Leaf);
        attempted=$false;timedOut=$false;processExited=$null;nativeExitCode=$null;error=$null}
    $helper=$null; $started=$false; $stdout=$null; $stderr=$null
    try {
        $Target.Refresh()
        if ($Target.HasExited -or -not $result.available) { return [pscustomobject]$result }
        $helper=New-Object Diagnostics.Process
        $helper.StartInfo.FileName=$Jcmd
        $helper.StartInfo.Arguments=([string]$Target.Id)+' Thread.print -l'
        $helper.StartInfo.UseShellExecute=$false
        $helper.StartInfo.CreateNoWindow=$true
        $helper.StartInfo.RedirectStandardOutput=$true
        $helper.StartInfo.RedirectStandardError=$true
        $result.attempted=$true
        $started=$helper.Start()
        if(-not $started){throw 'Could not start the diagnostic jcmd process.'}
        $stdout=$helper.StandardOutput.ReadToEndAsync()
        $stderr=$helper.StandardError.ReadToEndAsync()
        if(-not $helper.WaitForExit(5000)) {
            $result.timedOut=$true
            [void](Stop-OwnedJvmProbe $helper)
        }
        $result.processExited=$helper.HasExited
        if($result.processExited){$result.nativeExitCode=$helper.ExitCode}
        $tasks=[Threading.Tasks.Task[]]@($stdout,$stderr)
        if([Threading.Tasks.Task]::WaitAll($tasks,1000)) {
            [IO.File]::WriteAllText((Join-Path $Directory 'jcmd.stdout.log'),$stdout.GetAwaiter().GetResult(),(New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText((Join-Path $Directory 'jcmd.stderr.log'),$stderr.GetAwaiter().GetResult(),(New-Object Text.UTF8Encoding($false)))
        } else { $result.error='jcmd output pipes did not finish within one second.' }
    } catch { $result.error=$_.Exception.Message }
    finally {
        if($null -ne $helper) {
            try {
                if($started){[void](Stop-OwnedJvmProbe $helper);$result.processExited=$helper.HasExited
                    if($result.processExited){$result.nativeExitCode=$helper.ExitCode}}
            } catch { $result.error='jcmd cleanup failed: '+$_.Exception.Message }
            $helper.Dispose()
        }
    }
    [pscustomobject]$result
}

function Invoke-JvmLifecycleCase([string]$Mode, [string]$Java, [string]$Jcmd,
                                 [string]$Source, [string]$Directory, [int]$Limit) {
    New-Item -ItemType Directory -Path $Directory | Out-Null
    $token=[guid]::NewGuid().ToString('N')
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $samples=New-Object 'System.Collections.Generic.List[object]'
    $result=[ordered]@{mode=$Mode;state='failed';pid=$null;token=$token;
        bodyComplete=$false;returnReady=$false;exitRequested=$false;normalExitObserved=$false;
        shutdownHookEntered=$false;shutdownHookFinished=$false;processExited=$false;
        cleanupForced=$false;nativeExitCode=$null;streamsDrained=$false;
        timeoutSeconds=$Limit;elapsedSeconds=$null;threadCapture=$null;failure=$null;processSamples=@()}
    $process=New-Object Diagnostics.Process
    $started=$false; $stdoutFile=$null; $stderrFile=$null; $stdoutTask=$null; $stderrTask=$null
    $stdoutPath=Join-Path $Directory 'java.stdout.log'
    $stderrPath=Join-Path $Directory 'java.stderr.log'
    try {
        $process.StartInfo.FileName=$Java
        $arguments=@('--source','17',$Source,$Mode,$token)
        $process.StartInfo.Arguments=(($arguments | ForEach-Object {ConvertTo-JvmProbeArgument $_}) -join ' ')
        $process.StartInfo.WorkingDirectory=$Directory
        $process.StartInfo.UseShellExecute=$false
        $process.StartInfo.CreateNoWindow=$true
        $process.StartInfo.RedirectStandardInput=$true
        $process.StartInfo.RedirectStandardOutput=$true
        $process.StartInfo.RedirectStandardError=$true
        $stdoutFile=New-Object IO.FileStream($stdoutPath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::Read,1)
        $stderrFile=New-Object IO.FileStream($stderrPath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::Read,1)
        $started=$process.Start()
        if(-not $started){throw 'Could not start the owned Java baseline process.'}
        $result.pid=$process.Id
        $stdoutTask=$process.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
        $stderrTask=$process.StandardError.BaseStream.CopyToAsync($stderrFile)
        $process.StandardInput.Close()
        $lastSample=-10.0
        while(-not $process.WaitForExit(100)) {
            foreach($task in @($stdoutTask,$stderrTask)) {
                if($task.IsFaulted -or $task.IsCanceled){[void]$task.GetAwaiter().GetResult()}
            }
            if($clock.Elapsed.TotalSeconds-$lastSample -ge 5) {
                $samples.Add((Get-JvmProbeSample $process $clock))
                Write-Host ("JVM {0}: {1}s / {2}s (includes source compilation and shutdown)" -f $Mode,[Math]::Floor($clock.Elapsed.TotalSeconds),$Limit)
                $lastSample=$clock.Elapsed.TotalSeconds
            }
            if($clock.Elapsed.TotalSeconds -ge $Limit) {
                $result.state='timeout'
                $samples.Add((Get-JvmProbeSample $process $clock))
                Write-Host "JVM $Mode exceeded its deadline; collecting owned-process threads (at most 5 seconds)."
                $result.threadCapture=Get-JvmProbeThreads $process $Jcmd $Directory
                $result.cleanupForced=Stop-OwnedJvmProbe $process
                throw "Java $Mode did not exit within ${Limit}s; only this owned probe was targeted for cleanup."
            }
        }
        $result.normalExitObserved=$true
        $result.nativeExitCode=$process.ExitCode
        if($result.nativeExitCode -ne 0){throw "Java $Mode exited with native code $($result.nativeExitCode)."}
        $result.state='completed'
    } catch { $result.failure=$_.Exception.Message }
    finally {
        if($started) {
            try {
                $process.Refresh()
                if(-not $process.HasExited) {
                    $result.cleanupForced=(Stop-OwnedJvmProbe $process) -or $result.cleanupForced
                }
                $result.processExited=$process.HasExited
                if($result.processExited){$result.nativeExitCode=$process.ExitCode}
            } catch {
                $result.state='cleanup-failed'
                $result.failure=([string]$result.failure)+' Cleanup failed: '+$_.Exception.Message
            }
        }
        if($null -ne $stdoutTask -and $null -ne $stderrTask) {
            try {
                $tasks=[Threading.Tasks.Task[]]@($stdoutTask,$stderrTask)
                $result.streamsDrained=[Threading.Tasks.Task]::WaitAll($tasks,2000)
                if($result.streamsDrained){[void]$stdoutTask.GetAwaiter().GetResult();[void]$stderrTask.GetAwaiter().GetResult()}
            } catch {$result.streamsDrained=$false;$result.failure=([string]$result.failure)+' Output drain failed: '+$_.Exception.Message}
        }
        foreach($stream in @($stdoutFile,$stderrFile)){if($null -ne $stream){$stream.Dispose()}}
        $process.Dispose()
        $clock.Stop()
        $result.elapsedSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,3)
        $result.processSamples=@($samples.ToArray())
    }
    if(Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
        $lines=[IO.File]::ReadAllLines($stdoutPath)
        $prefix="JVM_LIFECYCLE token=$token mode=$Mode pid=$($result.pid) event="
        $result.bodyComplete=$lines -ccontains ($prefix+'BODY_COMPLETE')
        $result.returnReady=$lines -ccontains ($prefix+'RETURN_READY')
        $result.exitRequested=$lines -ccontains ($prefix+'EXIT_REQUESTED')
        $result.shutdownHookEntered=$lines -ccontains ($prefix+'SHUTDOWN_HOOK_ENTERED')
        $result.shutdownHookFinished=$lines -ccontains ($prefix+'SHUTDOWN_HOOK_FINISHED')
    }
    if($result.state -eq 'completed') {
        $terminationMarker=if($Mode -eq 'return'){$result.returnReady}else{$result.exitRequested}
        if($result.bodyComplete -and $terminationMarker -and $result.shutdownHookEntered -and
            $result.shutdownHookFinished -and $result.processExited -and $result.nativeExitCode -eq 0 -and
            $result.streamsDrained -and -not $result.cleanupForced -and -not $result.failure) {
            $result.state='passed'
        } else {
            $result.state='failed'
            if(-not $result.failure){$result.failure='Native completion, expected lifecycle markers, or complete output drainage was not verified.'}
        }
    }
    [pscustomobject]$result
}

function Protect-JvmProbeOptionEchoes([string]$Path) {
    $text=[IO.File]::ReadAllText($Path)
    foreach($key in @('JAVA_TOOL_OPTIONS','JDK_JAVA_OPTIONS','_JAVA_OPTIONS')) {
        $value=[Environment]::GetEnvironmentVariable($key)
        if($value) {
            # The JVM may echo embedded newlines too. Remove the exact complete
            # value in its announcement before the generic single-line fallback.
            $pattern='(?m)^(?:NOTE: )?Picked up '+$key+':[ \t]*'+[regex]::Escape($value)
            $text=[regex]::Replace($text,$pattern,('Picked up '+$key+': [redacted; setting remained active]'))
        }
    }
    $text=[regex]::Replace($text,'(?m)^(?:NOTE: )?Picked up (JAVA_TOOL_OPTIONS|JDK_JAVA_OPTIONS|_JAVA_OPTIONS):[^\r\n]*',
        'Picked up $1: [redacted; setting remained active]')
    [IO.File]::WriteAllText($Path,$text,(New-Object Text.UTF8Encoding($false)))
}

# Match the failed JDBC tool's default selection. Do not prefer an unrelated
# JAVA_HOME, invoke Common.ps1, or initialize the R/offline database runtime.
$selection=if($JavaHome){'explicit'}else{'default-temurin17'}
if(-not $JavaHome) {
    $candidates=@(Get-ChildItem -LiteralPath 'C:\Program Files\Eclipse Adoptium' -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'bin\java.exe')})
    if(-not $candidates.Count){throw 'Temurin 17 not found. Supply -JavaHome with the same JDK used by CHECK_JDBC.'}
    $JavaHome=$candidates[0].FullName
}
$JavaHome=(Resolve-Path -LiteralPath $JavaHome).Path
$javaName=if($env:OS -eq 'Windows_NT'){'java.exe'}else{'java'}
$jcmdName=if($env:OS -eq 'Windows_NT'){'jcmd.exe'}else{'jcmd'}
$java=Join-Path (Join-Path $JavaHome 'bin') $javaName
$jcmd=Join-Path (Join-Path $JavaHome 'bin') $jcmdName
$source=Join-Path $PSScriptRoot 'JvmLifecycleProbe.java'
foreach($required in @($java,$source)) {
    if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "JVM baseline dependency missing: $required"}
}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $BundleRoot 'FederatedPS\work\diagnostics'}
$name='jvm-lifecycle-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$out=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) $name
New-Item -ItemType Directory -Path $out -Force | Out-Null
$overall=[Diagnostics.Stopwatch]::StartNew()
Write-Host "JDK baseline executable: $java"
Write-Host "Logs: $out"
$cases=@()
foreach($mode in @('return','exit')) {
    $cases+=Invoke-JvmLifecycleCase $mode $java $jcmd $source (Join-Path $out $mode) $TimeoutSeconds
    Write-Host "JVM $mode result: $($cases[-1].state); native exit=$($cases[-1].nativeExitCode)"
}
$overall.Stop()
$state=if(@($cases | Where-Object {$_.state -ne 'passed'}).Count){'failed'}else{'passed'}
$ambient=[ordered]@{}
foreach($key in @('JAVA_TOOL_OPTIONS','JDK_JAVA_OPTIONS','_JAVA_OPTIONS','CLASSPATH')) {
    # Keep existing runtime/security settings; record presence, never their values.
    $ambient[$key]=[bool][Environment]::GetEnvironmentVariable($key)
}
$receipt=[ordered]@{schema=1;state=$state;javaExecutable=$java;javaHomeSelection=$selection;
    javaSourceSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant();
    timeoutSecondsPerCase=$TimeoutSeconds;timeoutIncludesSourceCompilation=$true;
    elapsedSeconds=[Math]::Round($overall.Elapsed.TotalSeconds,3);ambientJavaOptionsPresent=$ambient;
    cases=$cases;scope='JDK 17+ main return and System.exit(0) only; the probe code does not load R, JDBC, a database configuration or application JARs. Existing JVM/security settings are preserved.'}
$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding UTF8
# Preserve inherited agents/options for the comparison, but remove the runtime's
# automatic option-value announcements from all saved Java/jcmd logs before ZIP.
foreach($file in @(Get-ChildItem -LiteralPath $out -File -Recurse -Filter '*.log')) {
    Protect-JvmProbeOptionEchoes $file.FullName
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=$out+'.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($out,$zip,[IO.Compression.CompressionLevel]::Optimal,$true)
Write-Host "Diagnostic ZIP: $zip"
if($state -eq 'passed') {
    Write-Host 'PASS: both JDK baseline bodies, shutdown hooks and native process exits completed.' -ForegroundColor Green
    Write-Host 'This does not certify JDBC, R/rJava, CDM connectivity or cohort extraction.'
} else { throw 'JDK lifecycle baseline failed or timed out. Share the diagnostic ZIP shown above.' }
