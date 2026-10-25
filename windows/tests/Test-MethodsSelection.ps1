#Requires -Version 5.1
$ErrorActionPreference='Stop'
$project=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fps-selection-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    Copy-Item (Join-Path $project 'windows/Run-YUHS.ps1') $temp
    @'
param($Mode,$Dataset,$Methods,[bool]$Test=$true,$BlockSize,$Alpha)
[pscustomobject]@{mode=$Mode;dataset=$Dataset;methods=$Methods;test=$Test;block=$BlockSize;alpha=$Alpha}
'@ | Set-Content (Join-Path $temp 'Run-FederatedPS.ps1')
    @'
param($Methods,[bool]$Test=$true,$BlockSize,$Alpha,$PatientLimit,$PatientLimits,$CacheDirectory,[switch]$RebuildData,$StatusSeconds)
[pscustomobject]@{mode='SelectedMethods';methods=$Methods;test=$Test;block=$BlockSize;alpha=$Alpha;limit=$PatientLimit;limits=$PatientLimits;cache=$CacheDirectory;rebuild=[bool]$RebuildData;status=$StatusSeconds}
'@ | Set-Content (Join-Path $temp 'Run-YUHS-Methods.ps1')
    $run=Join-Path $temp 'Run-YUHS.ps1'
    $default=& $run
    if($default.mode -ne 'SelectedMethods' -or -not $default.test -or ($default.methods -join ',') -ne 'federated'){throw 'Default selection broken'}
    foreach($selection in @('local-only','pooled','federated','local-only,pooled','local-only,federated','pooled,federated','local-only,pooled,federated')){
        $m=$selection.Split(',');$r=& $run -Methods $m -Test $false -BlockSize 4 -Alpha 0.5 -PatientLimit 200 -PatientLimits @{2=100;3=300} -CacheDirectory 'fixture-cache' -RebuildData -StatusSeconds 10
        if($r.status -ne 10){throw 'Progress option lost'}
        if($r.test -or $r.block -ne 4 -or $r.alpha -ne 0.5){throw 'Settings lost'}
        if($r.mode -ne 'SelectedMethods' -or ($r.methods -join ',') -ne $selection){throw 'Bad selection dispatch'}
        if($r.limit -ne 200 -or $r.limits[2] -ne 100 -or $r.limits[3] -ne 300 -or $r.cache -ne 'fixture-cache' -or -not $r.rebuild){throw 'Patient/cache options lost'}
    }
    $r=& $run -Methods POOLED,LOCAL-ONLY
    if(($r.methods -join ',') -cne 'pooled,local-only'){throw 'Case normalization failed'}
    foreach($bad in @(@(),@('other'),@('pooled','POOLED'))){
        $caught=$false;try{& $run -Methods $bad | Out-Null}catch{$caught=$true}
        if(-not $caught){throw 'Invalid selection accepted'}
    }
    Write-Host 'PASS: all seven public method combinations, default compatibility, case normalization, invalid/empty/duplicate rejection.'
} finally {Remove-Item -LiteralPath $temp -Recurse -Force}
