"""Actual source-launched Java/JDBC against a loopback TDS fault fixture only."""
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
JAR = Path(os.environ["FPS_TEST_JDBC"]).resolve()
JAVA = os.environ.get("FPS_TEST_JAVA", "java")
USER = "alice"
PASSWORD = "aliceSecret9"


def exact(c, n):
    result = b""
    while len(result) < n:
        value = c.recv(n - len(result))
        if not value:
            raise EOFError()
        result += value
    return result


def read(c):
    data = b""
    while True:
        kind, status, n, _, _, _ = struct.unpack("!BBHHBB", exact(c, 8))
        data += exact(c, n - 8)
        if status & 1:
            return kind, data


def send(c, body, final=True):
    c.sendall(struct.pack("!BBHHBB", 4, int(final), len(body) + 8, 0, 1, 0) + body)


def done(status=0, rows=0):
    return b"\xfd" + struct.pack("<HHQ", status, 0, rows)


def col(name, text=False, korean=False):
    kind = b"\x38"
    if text:
        kind = (b"\xa7" if text == "varchar" else b"\xe7") + struct.pack("<H", 1024)
        kind += bytes.fromhex("1204000000" if korean else "0904d00034")
    return struct.pack("<IH", 0, 0) + kind + bytes([len(name)]) + name.encode("utf-16le")


def string_cell(value, encoding="utf-16le"):
    raw = value.encode(encoding)
    return struct.pack("<H", len(raw)) + raw


def error():
    msg = "Fixture SQL error for " + PASSWORD + " and " + USER
    server = "Fixture"
    body = struct.pack("<IBBH", 50000, 1, 16, len(msg)) + msg.encode("utf-16le")
    body += bytes([len(server)]) + server.encode("utf-16le") + b"\0" + struct.pack("<I", 1)
    return b"\xaa" + struct.pack("<H", len(body)) + body


def run(case, buffering="full", mode="care-site-id", text_type="nvarchar"):
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]
    queries, failures = [], []

    def serve():
        try:
            c, _ = server.accept()
            c.settimeout(12)
            with c:
                kind, _ = read(c)
                assert kind == 18
                send(c, b"\x00\x00\x0b\x00\x06\x01\x00\x11\x00\x01\xff" + b"\x0f\x00\x07\xd0\x00\x00\x02")
                kind, _ = read(c)
                assert kind == 16
                ack = b"\x01" + bytes.fromhex("74000004") + bytes([7]) + "Fixture".encode("utf-16le") + bytes([15, 0, 7, 208])
                send(c, b"\xad" + struct.pack("<H", len(ack)) + ack + done())
                while True:
                    kind, body = read(c)
                    if kind == 6:  # ATTENTION can accompany a JDBC query timeout.
                        continue
                    assert kind == 1, kind
                    header = struct.unpack("<I", body[:4])[0]
                    sql = body[header:].decode("utf-16le")
                    queries.append(sql)
                    if sql == "SELECT CAST(1 AS INT) AS ok, @@SPID AS session_id":
                        send(c, b"\x81\x02\x00" + col("ok") + col("session_id") + b"\xd1" + struct.pack("<ii", 1, 77) + done(0x10, 1))
                    elif sql.startswith("SELECT CAST(1 AS INT) AS probe_id"):
                        assert mode == "synthetic-text" and "Korean_Wansung_CI_AS" in sql, sql
                        response = b"\x81\x04\x00" + col("probe_id") + col("ascii_text", "varchar")
                        response += col("unicode_text", "nvarchar") + col("korean_varchar", "varchar", True)
                        response += b"\xd1" + struct.pack("<i", 1) + string_cell("FPS_ASCII", "ascii")
                        response += string_cell("한글") + string_cell("한글", "cp949")
                        send(c, response + done(0x10, 1))
                    elif sql.startswith("SELECT TOP (2)"):
                        site = int(re.search(r"care_site_id = ([0-9]+)$", sql)[1])
                        if mode == "care-site-id":
                            assert sql == f"SELECT TOP (2) care_site_id FROM fixture.CDM.CARE_SITE WHERE care_site_id = {site}", sql
                            response = b"\x81\x01\x00" + col("care_site_id") + b"\xd1" + struct.pack("<i", site)
                        else:
                            assert mode == "care-site-text" and "care_site_name, care_site_source_value" in sql, sql
                            response = b"\x81\x03\x00" + col("care_site_id") + col("care_site_name", text_type, text_type == "varchar")
                            response += col("care_site_source_value", text_type, text_type == "varchar")
                            response += b"\xd1" + struct.pack("<i", site)
                            response += string_cell("Synthetic 강남", "cp949" if text_type == "varchar" else "utf-16le") + b"\xff\xff"
                        if case == "late-error":
                            send(c, response + done(1 | 0x10, 1), False)
                            time.sleep(.05)
                            send(c, error() + done(2))
                        elif case == "stalled":
                            # The complete row is present but the final packet is
                            # withheld. No reply to ATTENTION: watchdog must exit.
                            send(c, response + done(1 | 0x10, 1), False)
                        else:
                            send(c, response, False)
                            time.sleep(.05)
                            send(c, done(0x10, 1))
                    else:
                        send(c, done())
        except (EOFError, ConnectionResetError, BrokenPipeError):
            pass
        except Exception as e:
            failures.append(repr(e))
        finally:
            server.close()

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    fields = [str(JAR), "127.0.0.1", str(port), "fixture", USER, PASSWORD, "fixture.CDM", "false", "false"]
    packet = "FPS_JAVA_PROBE_V1\n" + "\n".join(x.encode().hex() for x in fields) + "\n"
    begun = time.monotonic()
    result = subprocess.run([JAVA, "--class-path", str(JAR), str(ROOT / "windows/JdbcConnectionProbe.java"),
        "1", "4", buffering, "1,2,3", mode], input=packet, text=True, capture_output=True, timeout=12)
    elapsed = time.monotonic() - begun
    worker.join(2)
    assert not failures, failures
    text = result.stdout + result.stderr
    assert PASSWORD not in text and USER not in text and "[REDACTED]Secret9" not in text, text
    assert not any("SET ROWCOUNT" in q for q in queries), queries
    assert "SQL_SERVER_SPID=77" in text, text
    assert "PROBE_MODE=" + mode in text and "JAVA_HEARTBEAT" in result.stderr, text
    if case == "normal":
        assert result.returncode == 0 and "CHECKS_COMPLETE:" in text, text
        assert "START JVM termination System.exit(0)" in text, text
        sequence = ["DONE Connection.close", "CHECKS_COMPLETE:", "JAVA_PRE_EXIT_THREAD_DUMP_BEGIN",
                    "JAVA_PRE_EXIT_THREAD_DUMP_END", "START JVM termination System.exit(0)",
                    "JAVA_SHUTDOWN_HOOK_BEGIN", "JAVA_SHUTDOWN_HOOK_END"]
        positions = [result.stdout.index(marker) for marker in sequence]
        assert positions == sorted(positions), result.stdout
        assert "JAVA_SHUTDOWN_HOOK_BEGIN_RAW" in result.stderr and "JAVA_SHUTDOWN_HOOK_END_RAW" in result.stderr, result.stderr
        assert "name=[REDACTED]" in result.stdout, result.stdout
        expected = [] if mode == "synthetic-text" else [1, 2, 3]
        assert [int(re.search(r"care_site_id = ([0-9]+)$", q)[1]) for q in queries if q.startswith("SELECT TOP (2)")] == expected, queries
        count = 4 if mode == "synthetic-text" else 8
        assert text.count("Connection.restoreNetworkTimeout") == count, text
        assert text.count("Connection.isClosed") == count, text
        if mode == "care-site-id":
            assert "getString" not in text and "getMetaData column" not in text, text
        elif mode == "synthetic-text":
            assert "COLUMN_METADATA column=2 jdbc_type=12" in text, text
            assert "COLUMN_METADATA column=3 jdbc_type=-9" in text, text
            assert "COLUMN_METADATA column=4 jdbc_type=12" in text, text
        else:
            kind = "12" if text_type == "varchar" else "-9"
            assert "COLUMN_METADATA column=2 jdbc_type=" + kind in text, text
            assert "DONE CARE_SITE site_id=1 ResultSet.getString row=1 column=2" in text, text
            assert "DONE CARE_SITE site_id=1 ResultSet.wasNull row=1 column=2" in text, text
    elif case == "late-error":
        assert result.returncode == 2 and "CHECKS_COMPLETE:" not in text, text
        assert "START JVM termination System.exit(2)" in text, text
        assert text.count("FIRST_FAILURE") == 1, text
        assert "Statement.getMoreResults" in text and "Fixture SQL error for [REDACTED] and [REDACTED]" in text, text
        assert "SQLSTATE=" in text, text
    elif case == "shutdown":
        # Launcher fixture injects a hanging JVM shutdown hook only after all
        # actual JDBC checks and connection.close have finished.
        assert result.returncode != 0 and "CHECKS_COMPLETE:" in text, text
        assert "START JVM termination System.exit(0)" in text, text
    elif case == "post-check":
        assert result.returncode == 124 and "CHECKS_COMPLETE:" in text, text
        assert "JAVA_PRE_EXIT_THREAD_DUMP_BEGIN" in text and "JAVA_PRE_EXIT_THREAD_DUMP_END" not in text, text
        assert "START JVM termination System.exit(" not in text, text
    else:
        assert result.returncode == 124 and elapsed < 12 and "CHECKS_COMPLETE:" not in text, text
        assert "JAVA_WATCHDOG_TIMEOUT" in text and "JAVA_THREAD_DUMP_BEGIN" in text and "JAVA_THREAD_DUMP_END" in text, text
        assert "JAVA_WATCHDOG_TIMEOUT_RAW" in result.stderr, text
    print("PASS", case, mode, text_type, buffering, "exit", result.returncode, "seconds", round(elapsed, 2), flush=True)


if __name__ == "__main__":
    run("normal")
    run("normal", "adaptive")
    run("normal", mode="care-site-text")
    run("normal", mode="care-site-text", text_type="varchar")
    run("normal", mode="synthetic-text")
    run("late-error")
    run("stalled")
    print("PASS: JDK source launch, selected JDBC, numeric/legacy/synthetic modes, NVARCHAR/CP949/NULL fetch, terminal errors, private input/redaction, raw heartbeat and bounded independent watchdog")
