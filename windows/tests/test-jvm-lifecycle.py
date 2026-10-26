#!/usr/bin/env python3
"""Real JDK/PowerShell baseline and failure regressions; no R or database needed.

Run on Linux with --pwsh /path/to/pwsh --java-home /path/to/jdk17.
The fake jcmd only tests the parent's bounded cleanup; it does not emulate JVM
thread inspection. These tests do not certify Windows PowerShell 5.1 behavior.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import zipfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pwsh", required=True)
    parser.add_argument("--java-home", required=True)
    args = parser.parse_args()
    windows = Path(__file__).resolve().parents[1]
    source = (windows / "JvmLifecycleProbe.java").read_text()
    java_home = Path(args.java_home).resolve()
    with tempfile.TemporaryDirectory(prefix="fps-jvm-regression-") as temporary:
        root = Path(temporary)

        def run(name, code, *, hang_jcmd=False, redact=False):
            fixture = root / name
            fixture.mkdir()
            shutil.copy2(windows / "Test-JvmLifecycle.ps1", fixture)
            (fixture / "JvmLifecycleProbe.java").write_text(code)
            selected_home = java_home
            if hang_jcmd:
                selected_home = fixture / "jdk"
                (selected_home / "bin").mkdir(parents=True)
                (selected_home / "bin" / "java").symlink_to(java_home / "bin" / "java")
                jcmd = selected_home / "bin" / "jcmd"
                jcmd.write_text("#!/usr/bin/env python3\nimport time\nprint('fixture jcmd started', flush=True)\ntime.sleep(60)\n")
                jcmd.chmod(0o755)
            environment = os.environ.copy()
            if redact:
                extra = "-Dfps.redaction.one=baseline-sentinel\n-Dfps.redaction.two=second-sentinel"
                environment["JAVA_TOOL_OPTIONS"] = (environment.get("JAVA_TOOL_OPTIONS", "") + " " + extra).strip()
            started = time.monotonic()
            completed = subprocess.run([
                args.pwsh, "-NoLogo", "-NoProfile", "-File", str(fixture / "Test-JvmLifecycle.ps1"),
                "-JavaHome", str(selected_home), "-OutputDirectory", str(fixture / "output"),
                "-TimeoutSeconds", "5"], env=environment, text=True, capture_output=True, timeout=40)
            archives = list((fixture / "output").glob("*.zip"))
            assert len(archives) == 1, completed.stdout + completed.stderr
            with zipfile.ZipFile(archives[0]) as archive:
                result_file = next(n for n in archive.namelist() if n.endswith("/result.json"))
                result = json.loads(archive.read(result_file).decode("utf-8-sig"))
                if redact:
                    all_logs = b"\n".join(archive.read(n) for n in archive.namelist() if n.endswith(".log"))
                    assert b"baseline-sentinel" not in all_logs and b"second-sentinel" not in all_logs
                    assert b"redacted; setting remained active" in all_logs
            assert all(case["processExited"] for case in result["cases"]), result
            return completed.returncode, result, time.monotonic() - started

        code, result, _ = run("normal", source, redact=True)
        assert code == 0 and result["state"] == "passed", result
        assert result["ambientJavaOptionsPresent"]["JAVA_TOOL_OPTIONS"]
        assert all(case["bodyComplete"] and case["shutdownHookFinished"] and
                   case["normalExitObserved"] and not case["cleanupForced"] and
                   case["nativeExitCode"] == 0 for case in result["cases"]), result

        code, result, _ = run("native-error", source.replace("System.exit(0)", "System.exit(7)"))
        assert code != 0 and result["cases"][0]["state"] == "passed", result
        failed = result["cases"][1]
        assert failed["state"] == "failed" and failed["nativeExitCode"] == 7
        assert failed["bodyComplete"] and failed["shutdownHookFinished"] and failed["normalExitObserved"]

        sleeper = 'new Thread(() -> { try { Thread.sleep(60000); } catch (InterruptedException ignored) { } }, "fixture-stall").start();'
        code, result, elapsed = run("shutdown-stall", source.replace('marker("BODY_COMPLETE");', sleeper + '\n        marker("BODY_COMPLETE");'), hang_jcmd=True)
        stalled = result["cases"][0]
        assert code != 0 and stalled["state"] == "timeout" and stalled["bodyComplete"], result
        assert stalled["cleanupForced"] and not stalled["normalExitObserved"] and stalled["nativeExitCode"] != 0
        assert stalled["threadCapture"]["timedOut"] and stalled["threadCapture"]["processExited"]
        assert result["cases"][1]["state"] == "passed" and elapsed < 25, result
        print("PASS: real Java return/exit, native failure despite complete markers, bounded JVM/jcmd cleanup, multiline option-echo redaction.")


if __name__ == "__main__":
    main()
