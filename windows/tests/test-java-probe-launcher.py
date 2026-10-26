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
shutdown_fixture = False
compiled_fixture = False
snapshot_fixture = False


def through_powershell(argv, input, **kwargs):
    fields = [bytes.fromhex(line).decode() for line in input.splitlines()[1:]]
    capture = len(argv) == 10 and argv[9] == "true"
    mode = argv[8]
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
        selected_java = os.environ.get("FPS_TEST_JAVA11") if compiled_fixture else None
        selected_java = selected_java or os.environ.get("FPS_TEST_JAVA", "java")
        (java_home / "bin/java.exe").symlink_to(Path(shutil.which(selected_java)).resolve())
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
        # The loopback fixture must not emit optional PowerShell/.NET telemetry.
        environment["POWERSHELL_TELEMETRY_OPTOUT"] = "1"
        environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        # Also verify inherited package requests cannot cause this exporter to
        # initialize rJava. The actual launcher overrides R_DEFAULT_PACKAGES.
        environment["R_DEFAULT_PACKAGES"] = "rJava"
        launcher = ROOT / "windows/Test-JavaConnection.ps1"
        if shutdown_fixture or compiled_fixture or snapshot_fixture:
            # Modify only a temporary copy: keep the real Java checks/close,
            # then block a JVM shutdown hook beyond the external deadline.
            fixture_tools = root / "fixture tools"
            fixture_tools.mkdir()
            for name in ("Test-JavaConnection.ps1", "java-probe-config.R"):
                shutil.copy2(ROOT / "windows" / name, fixture_tools / name)
            java_source = (ROOT / "windows/JdbcConnectionProbe.java").read_text()
            if compiled_fixture:
                # Verify thread metadata cannot leak even a secret-bearing name.
                java_source = java_source.replace('start("Read private configuration"); readConfig(); end();',
                    'start("Read private configuration"); readConfig(); end();\n'
                    'Thread secretThread = new Thread(() -> { try { Thread.sleep(60000); } catch (InterruptedException ignored) {} }, "'
                    + wire.PASSWORD + '"); secretThread.setDaemon(true); secretThread.start();')
            if shutdown_fixture:
                java_source = java_source.replace("watchdog(totalTimeout, queryTimeout + 15);", "watchdog(3600, 3600);")
                java_source = java_source.replace("System.exit(code);", '''Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                try { Thread.sleep(60000); } catch (InterruptedException ignored) { }
            }, "fixture-shutdown-stall"));
            System.exit(code);''')
            if snapshot_fixture:
                java_source = java_source.replace('log("JAVA_PRE_EXIT_THREAD_DUMP_BEGIN");',
                    'log("JAVA_PRE_EXIT_THREAD_DUMP_BEGIN");\n'
                    'try { Thread.sleep(60000); } catch (InterruptedException ignored) {}')
            fixture_source = fixture_tools / "JdbcConnectionProbe.java"
            fixture_source.write_text(java_source)
            if compiled_fixture:
                classes = fixture_tools / "java11"
                classes.mkdir()
                javac = os.environ.get("FPS_TEST_JAVAC") or shutil.which("javac")
                compiler = [javac] if javac else [os.environ.get("FPS_TEST_JAVA", "java"), "-m", "jdk.compiler/com.sun.tools.javac.Main"]
                compilation = real_run(compiler + ["--release", "11", "-d", str(classes), str(fixture_source)],
                    text=True, capture_output=True, timeout=15)
                assert compilation.returncode == 0, compilation.stdout + compilation.stderr
                bytecode = (classes / "JdbcConnectionProbe.class").read_bytes()
                assert bytecode[:4] == bytes.fromhex("cafebabe") and int.from_bytes(bytecode[6:8], "big") == 55
                # Compiled mode must not read or attempt to compile this source.
                fixture_source.write_text("intentionally invalid fixture source; use compiled class only")
                # The target process cannot see jdk.compiler in this fixture.
                # These test-only options are never added by the real launcher.
                environment["JDK_JAVA_OPTIONS"] = "--limit-modules=java.se"
            launcher = fixture_tools / "Test-JavaConnection.ps1"
        command = [os.environ["FPS_PWSH"], "-NoLogo", "-NoProfile", "-File",
            str(launcher), "-Project", str(project),
            "-SmallQueryTimeoutSeconds", "1", "-TimeoutSeconds", "15", "-ProbeMode", mode]
        if capture:
            command.append("-CapturePreExitThreads")
        result = real_run(command,
            text=True, capture_output=True, env=environment, timeout=40 if shutdown_fixture else 25)
        archives = list((project / "work/diagnostics").glob("*.zip"))
        assert len(archives) == 1, result.stdout + result.stderr
        with zipfile.ZipFile(archives[0]) as archive:
            names = archive.namelist()
            assert len(names) == 3, names
            texts = {Path(name).name: archive.read(name).decode("utf-8-sig") for name in names}
        receipt = json.loads(texts["result.json"])
        assert receipt["independentJvm"] and receipt["sites"] == [1, 2, 3], receipt
        assert receipt["probeMode"] == mode and receipt["capturePreExitThreads"] == capture, receipt
        assert receipt["launchMode"] == ("compiled-java11" if compiled_fixture else "source"), receipt
        # Process metrics may be unavailable on a host that does not expose its
        # child process table. Preserve null rather than inventing a zero value.
        assert receipt["processSamples"] and all(
            (x["cpuSeconds"] is None or x["cpuSeconds"] >= 0) and
            (x["threads"] is None or x["threads"] > 0) for x in receipt["processSamples"]), receipt
        snapshot_stall = snapshot_fixture and capture
        expected = "post-check-timeout" if snapshot_stall else "shutdown-timeout" if shutdown_fixture else "passed" if receipt["exitCode"] == 0 else "failed"
        assert receipt["state"] == expected, receipt
        assert receipt["processExited"] and receipt["outputDrained"], receipt
        assert Path(receipt["javaExecutable"]) == java_home / "bin/java.exe", receipt
        assert receipt["normalExitObserved"] == (expected == "passed"), receipt
        assert receipt["checksComplete"] == (expected in ("passed", "shutdown-timeout", "post-check-timeout")), receipt
        assert receipt["forcedTermination"] == shutdown_fixture, receipt
        assert receipt["terminationRequested"] == (not snapshot_stall), receipt
        assert receipt["snapshotStarted"] == (capture and expected != "failed"), receipt
        assert receipt["snapshotFinished"] == (capture and expected in ("passed", "shutdown-timeout")), receipt
        if shutdown_fixture:
            assert "process shutdown failure, not a query timeout" in receipt["failure"], receipt
        if snapshot_stall:
            assert "does not prove shutdown had started" in receipt["failure"], receipt
        assert (result.returncode == 0) == (receipt["state"] == "passed"), result.stdout + result.stderr
        all_output = result.stdout + result.stderr + "".join(texts.values())
        assert fields[4] not in all_output and fields[5] not in all_output, all_output
        assert "FPS_JAVA_PROBE_V1" not in all_output and fields[5].encode().hex() not in all_output, all_output
        return types.SimpleNamespace(returncode=receipt["exitCode"], stdout=texts["java.stdout.log"], stderr=texts["java.stderr.log"])


wire.subprocess = types.SimpleNamespace(run=through_powershell)
wire.run("normal")
wire.run("normal", capture=True)
wire.run("normal", mode="synthetic-text")
wire.run("late-error")
compiled_fixture = True
wire.run("normal")
wire.run("late-error")
compiled_fixture = False
shutdown_fixture = True
wire.run("shutdown")
shutdown_fixture = False
snapshot_fixture = True
compiled_fixture = True
# The compiled default succeeds even though the snapshot method would hang.
wire.run("normal")
wire.run("post-check", capture=True)
print("PASS: actual PowerShell/private base-R/standalone JDBC pipeline, mapping, success/failure receipt, ZIP and no credentials/private packet in outputs")
