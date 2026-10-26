#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $root 'Common.ps1')
. (Join-Path $root 'OdbcDiagnostic.Common.ps1')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fps-odbc-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$child=Join-Path $temp 'fake probe.ps1'
@'
param([string]$Out,[string]$Token,[string]$Case)
$ErrorActionPreference='Stop'
if($Case -ne 'missing'){
 $record=@{token=$Token;pid=$PID;mode='native';state='checks-complete';phase='R natural exit';phaseState='requested';
 checks=@('self-check','site-1','site-2','site-3','typed-temp-table','same-session','temp-cleanup','disconnect')}
 if($Case -eq 'mismatch'){$record.token='wrong'}
 if($Case -eq 'incomplete'){$record.checks=@('self-check')}
 [IO.File]::WriteAllText($Out,($record|ConvertTo-Json))
}
if($Case -eq 'hang'){Start-Sleep -Seconds 30}
if($Case -eq 'failed'){exit 2}
exit 0
'@ | Set-Content -LiteralPath $child -Encoding UTF8
$passed=0
try{
 foreach($case in @('good','missing','mismatch','incomplete','failed','hang')){
  $status=Join-Path $temp ($case+'.json');$token=[guid]::NewGuid().ToString('N')
  $p=New-Object Diagnostics.Process;$started=$false
  try{
   $p.StartInfo=New-Object Diagnostics.ProcessStartInfo
   $binary=if($env:OS -ne 'Windows_NT'){'pwsh'}elseif($PSVersionTable.PSEdition -eq 'Core'){'pwsh.exe'}else{'powershell.exe'}
   $p.StartInfo.FileName=Join-Path $PSHOME $binary
   $p.StartInfo.Arguments=((@('-NoLogo','-NoProfile','-File',$child,$status,$token,$case)|ForEach-Object{ConvertTo-NativeArgument $_})-join ' ')
   $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true
   $p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
   $started=$p.Start();if(-not $started){throw 'Fake probe failed to start.'}
   $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
   $failure=$null;$answer=$null
   try{$answer=Wait-FederatedOdbcProbe -Process $p -StatusPath $status -Token $token -Mode native -SiteIds @(1,2,3) -TimeoutSeconds 2}
   catch{$failure=$_}
   if($case -eq 'good'){
    if($failure -or -not $answer.naturalExit -or $answer.exitCode -ne 0){throw 'Valid normal exit was rejected.'}
   }elseif(-not $failure){throw "Invalid probe accepted: $case"}
   if($case -eq 'hang'){
    $p.Refresh();if($p.HasExited){throw 'The watchdog should signal failure for caller-owned cleanup.'}
    Stop-FederatedProcessTree $p
    if(-not $p.HasExited){throw 'Owned process cleanup failed.'}
   }
   $passed++
  }finally{
   if($started -and -not $p.HasExited){Stop-FederatedProcessTree $p}
   $p.Dispose()
  }
 }
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
Write-Host "PASS: $passed ODBC process outcomes; completion plus natural exit is mandatory."
