"""Build the standalone probe for Java 11+ runtimes without a compiler.

Run on the online/build host: python windows/build-jdbc-probe.py OUTPUT_DIRECTORY
Requires javac 11+ on PATH (or FPS_JAVAC); does not download anything.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

source = Path(__file__).resolve().with_name("JdbcConnectionProbe.java")
if len(sys.argv) != 2:
    raise SystemExit("Usage: build-jdbc-probe.py OUTPUT_DIRECTORY")
destination = Path(sys.argv[1]).resolve()
compiler = [os.environ["FPS_JAVAC"]] if os.environ.get("FPS_JAVAC") else (
    [shutil.which("javac")] if shutil.which("javac") else
    [shutil.which("java") or "java", "-m", "jdk.compiler/com.sun.tools.javac.Main"])
with tempfile.TemporaryDirectory(prefix="fps-jdbc-java11-") as directory:
    compiled = Path(directory)
    subprocess.run(compiler + ["--release", "11", "-encoding", "UTF-8", "-d", str(compiled), str(source)], check=True)
    classes = sorted(compiled.glob("JdbcConnectionProbe*.class"))
    if not classes or not (compiled / "JdbcConnectionProbe.class").is_file():
        raise RuntimeError("Compiler did not produce the probe class")
    destination.mkdir(parents=True, exist_ok=True)
    hashes = {}
    for file in classes:
        data = file.read_bytes()
        if data[:4] != b"\xca\xfe\xba\xbe" or int.from_bytes(data[6:8], "big") != 55:
            raise RuntimeError("Expected Java 11 bytecode")
        (destination / file.name).write_bytes(data)
        hashes[file.name] = hashlib.sha256(data).hexdigest()
    manifest = {"targetJava": 11, "classMajorVersion": 55,
                "sourceSha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                "classes": hashes}
    (destination / "build.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest))
