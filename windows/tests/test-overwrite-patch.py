"""Exercise the actual PowerShell overwrite/rebuild launcher on synthetic files."""
from pathlib import Path
import json, os, shutil, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[2]
PWSH=os.environ.get('FPS_PWSH','pwsh')
SCRIPT=ROOT/'windows/Apply-FreshPatch.ps1'

def setup(path, fail_rebuild=False):
 bundle=path/'bundle';patch=path/'patch'
 bundle.mkdir(parents=True);(patch/'payload').mkdir(parents=True)
 old={'RUN.ps1':b'# arbitrary user edits\r\nWrite-Output custom\r\n',
      'FederatedPS/DESCRIPTION':b'Package: FederatedPs\nVersion: 0.0.10\n',
      'FederatedPS/R/fix.R':b'user modified source\n',
      'BUNDLE_MANIFEST.json':b'not even JSON: local edits\n',
      '10_UPDATE_PACKAGE.ps1':b'throw "old integrity gate must not run"\n',
      'FederatedPS/windows/config/yuhs.Renviron':b'DB_PASSWORD=fixture\n',
      'FederatedPS/work/retained.txt':b'retained result'}
 updater='param($InstallRoot)\n'
 updater+= 'throw "fixture reinstall failed"\n' if fail_rebuild else '[IO.File]::WriteAllText((Join-Path $PSScriptRoot "installed.txt"),$InstallRoot)\n'
 old['FederatedPS/windows/Update-FederatedPs.ps1']=updater.encode()
 for k,v in old.items():
  p=bundle/k;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(v)
 new={'RUN.ps1':b'param([hashtable]$PatientLimits=@{1=2;2=2;3=2})\n',
      'FederatedPS/R/fix.R':b'fixed release source\n',
      'BUNDLE_MANIFEST.json':b'{"source":"new release"}\n',
      'FederatedPS/R/new.R':b'new release file\n'}
 entries=[]
 for k,v in new.items():
  p=patch/'payload'/k;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(v)
  entries.append({'path':k,'bytes':-1,'sha256':'intentionally-irrelevant','oldSha256':'does-not-match'})
 (patch/'PATCH.json').write_text(json.dumps({'id':'jdbc-probe-3','files':entries,'bases':[]}))
 shutil.copy2(SCRIPT,patch/'APPLY_FIX.ps1')
 return bundle,patch,old,new

def run(bundle,patch,*extra,wrapper=None):
 script=wrapper or patch/'APPLY_FIX.ps1'
 return subprocess.run([PWSH,'-NoProfile','-File',str(script),'-BundleRoot',str(bundle),'-InstallRoot','fixture-install',*extra],text=True,capture_output=True)

with tempfile.TemporaryDirectory(prefix='fps overwrite ') as value:
 base=Path(value)
 bundle,patch,old,new=setup(base/'normal')
 for attempt in range(2):
  (bundle/'RUN.ps1').write_bytes(old['RUN.ps1']+b'# another edit\n')
  before=(bundle/'RUN.ps1').read_bytes()
  r=run(bundle,patch);assert r.returncode==0,r.stdout+r.stderr
  assert all((bundle/k).read_bytes()==v for k,v in new.items())
  assert (bundle/'FederatedPS/windows/installed.txt').read_text()=='fixture-install'
  backups=list((bundle/'patch-backups').glob('*/RUN.ps1'))
  assert len(backups)==attempt+1 and all(p.read_bytes()==before for p in backups)
  for k in ('FederatedPS/windows/config/yuhs.Renviron','FederatedPS/work/retained.txt'):
   assert (bundle/k).read_bytes()==old[k]
 bundle,patch,old,new=setup(base/'rebuild-failure',True)
 r=run(bundle,patch);assert r.returncode!=0 and 'package installation failed' in r.stderr,r.stdout+r.stderr
 assert (bundle/'RUN.ps1').read_bytes()==new['RUN.ps1'] and 'PASS: FederatedPs reinstalled' not in r.stdout
 bundle,patch,old,new=setup(base/'skip-rebuild',True)
 r=run(bundle,patch,'-SkipPackageRebuild');assert r.returncode==0,r.stdout+r.stderr
 bundle,patch,old,new=setup(base/'missing-payload')
 (patch/'payload/FederatedPS/R/new.R').unlink()
 r=run(bundle,patch);assert r.returncode!=0
 assert all((bundle/k).read_bytes()==v for k,v in old.items()) and not (bundle/'patch-backups').exists()
 # A mid-copy failure rolls back even though local files differ from release hashes.
 bundle,patch,old,new=setup(base/'copy-failure')
 wrapper=patch/'wrapper.ps1'
 wrapper.write_text('''param($BundleRoot,$InstallRoot)
function Copy-Item { param($LiteralPath,$Destination,[switch]$Force)
 if($LiteralPath.Replace('\\','/').EndsWith('/payload/FederatedPS/R/fix.R')){throw 'fixture copy failure'}
 Microsoft.PowerShell.Management\\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
}
& (Join-Path $PSScriptRoot 'APPLY_FIX.ps1') -BundleRoot $BundleRoot -InstallRoot $InstallRoot
''')
 r=run(bundle,patch,wrapper=wrapper);assert r.returncode!=0 and 'source files restored' in r.stderr,r.stdout+r.stderr
 assert all((bundle/k).read_bytes()==v for k,v in old.items())
 assert not (bundle/'FederatedPS/R/new.R').exists()
 for malicious in ['../outside.ps1','FederatedPS/windows/config/yuhs.Renviron','FederatedPS/work/patient.txt']:
  bundle,patch,old,new=setup(base/('bad'+str(len(malicious))))
  (patch/'PATCH.json').write_text(json.dumps({'files':[{'path':malicious}]}))
  r=run(bundle,patch);assert r.returncode!=0
  assert all((bundle/k).read_bytes()==v for k,v in old.items())
 print('PASS: arbitrary local edits and stale/invalid hashes ignored; overwrite, backup, automatic reinstall, repeat apply, failure propagation, copy rollback, local settings/data and path boundaries.')
