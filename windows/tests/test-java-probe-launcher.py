"""Exercise actual PowerShell launcher + private base-R exporter + actual JDBC.
Set FPS_PWSH, FPS_TEST_R, FPS_TEST_JDBC; source the local R environment first.
Only Windows installation discovery/process primitives are replaced for Linux.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import types
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("wire", ROOT / "windows/tests/test-java-connection-probe.py")
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)
real_run = subprocess.run


def through_powershell(argv, input, **kwargs):
    fields = [bytes.fromhex(line).decode() for line in input.splitlines()[1:]]
    with tempfile.TemporaryDirectory(prefix="fps-java-launcher-") as temporary:
        root = Path(temporary)
        project = root / "project space"
        windows = project / "windows"
        config = windows / "config"
        config.mkdir(parents=True)
        for name in ("common.R", "jdbc-driver.R", "runtime-lock.json"):
            shutil.copy2(ROOT / "windows" / name, windows / name)
        keys = ["DB_JDBC_JAR", "DB_SERVER", "DB_PORT", "DB_DATABASE", "DB_USER", "DB_PASSWORD", "CDM_DATABASE_SCHEMA", "DB_ENCRYPT", "DB_TRUST_SERVER_CERTIFICATE"]
        settings = 'DBMS="sql server"\n' + "\n".join(key + "=" + json.dumps(value) for key, value in zip(keys, fields)) + "\n"
        (config / "yuhs.Renviron").write_text(settings)
        (config / "yuhs-sites.json").write_text(json.dumps({"siteA": 1, "siteB": 2, "siteC": 3}))
        shim = root / "Rscript-shim"
        shim.write_text('#!/bin/sh\nshift\nscript=$1\nshift\nexec "$FPS_TEST_R" --vanilla --slave --file="$script" --args "$@"\n')
        shim.chmod(0o755)
        java_home = root / "jdk"
        (java_home / "bin").mkdir(parents=True)
        (java_home / "bin/java.exe").symlink_to(Path(shutil.which(os.environ.get("FPS_TEST_JAVA", "java"))).resolve())
        (windows / "Common.ps1").write_text(r'''
function Set-FederatedEnvironment {
    param($InstallRoot,$RHome,$JavaHome)
    $env:JAVA_HOME=$env:FPS_FIXTURE_JAVA_HOME
    [pscustomobject]@{Rscript=$env:FPS_FIXTURE_RSCRIPT}
}
function ConvertTo-NativeArgument([string]$Value) { '"'+$Value.Replace('"','\"')+'"' }
function Stop-FederatedProcessTree($Process) {
    $Process.Refresh()
    if(-not $Process.HasExited){$Process.Kill($true);[void]$Process.WaitForExit(10000)}
}
''')
        environment = os.environ.copy()
        environment.update(FPS_FIXTURE_JAVA_HOME=str(java_home), FPS_FIXTURE_RSCRIPT=str(shim))
        # Also verify inherited package requests cannot cause this exporter to
        # initialize rJava. The actual launcher overrides R_DEFAULT_PACKAGES.
        environment["R_DEFAULT_PACKAGES"] = "rJava"
        result = real_run([os.environ["FPS_PWSH"], "-NoLogo", "-NoProfile", "-File",
            str(ROOT / "windows/Test-JavaConnection.ps1"), "-Project", str(project),
            "-SmallQueryTimeoutSeconds", "1", "-TimeoutSeconds", "15"],
            text=True, capture_output=True, env=environment, timeout=25)
        archives = list((project / "work/diagnostics").glob("*.zip"))
        assert len(archives) == 1, result.stdout + result.stderr
        with zipfile.ZipFile(archives[0]) as archive:
            names = archive.namelist()
            assert len(names) == 3, names
            texts = {Path(name).name: archive.read(name).decode("utf-8-sig") for name in names}
        receipt = json.loads(texts["result.json"])
        assert receipt["independentJvm"] and receipt["sites"] == [1, 2, 3], receipt
        assert receipt["state"] == ("passed" if receipt["exitCode"] == 0 else "failed"), receipt
        assert (result.returncode == 0) == (receipt["state"] == "passed"), result.stdout + result.stderr
        all_output = result.stdout + result.stderr + "".join(texts.values())
        assert fields[4] not in all_output and fields[5] not in all_output, all_output
        assert "FPS_JAVA_PROBE_V1" not in all_output and fields[5].encode().hex() not in all_output, all_output
        return types.SimpleNamespace(returncode=receipt["exitCode"], stdout=texts["java.stdout.log"], stderr=texts["java.stderr.log"])


wire.subprocess = types.SimpleNamespace(run=through_powershell)
wire.run("normal")
wire.run("late-error")
print("PASS: actual PowerShell/private base-R/standalone JDBC pipeline, mapping, success/failure receipt, ZIP and no credentials/private packet in outputs")
