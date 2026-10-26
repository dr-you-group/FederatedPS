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


def col(name, text=False):
    kind = b"\xe7" + struct.pack("<H", 1024) + bytes.fromhex("0904d00034") if text else b"\x38"
    return struct.pack("<IH", 0, 0) + kind + bytes([len(name)]) + name.encode("utf-16le")


def error():
    msg = "Fixture SQL error for " + PASSWORD + " and " + USER
    server = "Fixture"
    body = struct.pack("<IBBH", 50000, 1, 16, len(msg)) + msg.encode("utf-16le")
    body += bytes([len(server)]) + server.encode("utf-16le") + b"\0" + struct.pack("<I", 1)
    return b"\xaa" + struct.pack("<H", len(body)) + body


def run(case, buffering="full"):
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
                    elif sql.startswith("SELECT TOP (2)"):
                        site = int(re.search(r"care_site_id = ([0-9]+)$", sql)[1])
                        name = "Synthetic 강남".encode("utf-16le")
                        response = b"\x81\x03\x00" + col("care_site_id") + col("care_site_name", True) + col("care_site_source_value", True)
                        response += b"\xd1" + struct.pack("<iH", site, len(name)) + name + b"\xff\xff"
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
        "1", "4", buffering, "1,2,3"], input=packet, text=True, capture_output=True, timeout=12)
    elapsed = time.monotonic() - begun
    worker.join(2)
    assert not failures, failures
    text = result.stdout + result.stderr
    assert PASSWORD not in text and USER not in text and "[REDACTED]Secret9" not in text, text
    assert not any("SET ROWCOUNT" in q for q in queries), queries
    assert "SQL_SERVER_SPID=77" in text, text
    if case == "normal":
        assert result.returncode == 0 and "CHECKS_COMPLETE:" in text, text
        assert [int(re.search(r"care_site_id = ([0-9]+)$", q)[1]) for q in queries if q.startswith("SELECT TOP (2)")] == [1, 2, 3], queries
        assert text.count("Connection.restoreNetworkTimeout") == 8, text
        assert text.count("Connection.isClosed") == 8, text
    elif case == "late-error":
        assert result.returncode == 2 and "CHECKS_COMPLETE:" not in text, text
        assert text.count("FIRST_FAILURE") == 1, text
        assert "Statement.getMoreResults" in text and "Fixture SQL error for [REDACTED] and [REDACTED]" in text, text
        assert "SQLSTATE=" in text, text
    else:
        assert result.returncode == 124 and elapsed < 12 and "CHECKS_COMPLETE:" not in text, text
        assert "JAVA_WATCHDOG_TIMEOUT" in text and "JAVA_THREAD_DUMP_BEGIN" in text and "JAVA_THREAD_DUMP_END" in text, text
    print("PASS", case, buffering, "exit", result.returncode, "seconds", round(elapsed, 2), flush=True)


if __name__ == "__main__":
    run("normal")
    run("normal", "adaptive")
    run("late-error")
    run("stalled")
    print("PASS: JDK source launch, selected JDBC, same SQL sequence, UTF-8/NULL fetch, terminal errors, private input/redaction, bounded independent watchdog")
