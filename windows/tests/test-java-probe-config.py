"""Real base-R export with synthetic credentials; never opens a DB connection."""
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
r = os.environ.get('FPS_TEST_R', 'R')
jar = Path(os.environ['FPS_TEST_JDBC']).resolve()
env = dict(os.environ, R_DEFAULT_PACKAGES='base')
with tempfile.TemporaryDirectory(prefix='java-probe-config-') as tmp:
    config = Path(tmp) / 'settings with spaces.Renviron'
    fields = [str(jar), '127.0.0.1', '1433', 'CDM54_2601', 'fixtureUser',
              'fixtureUserSecret9_한글', 'CDM54_2601.CDM', 'false', 'false']
    names = ['DB_JDBC_JAR', 'DB_SERVER', 'DB_PORT', 'DB_DATABASE', 'DB_USER',
             'DB_PASSWORD', 'CDM_DATABASE_SCHEMA', 'DB_ENCRYPT', 'DB_TRUST_SERVER_CERTIFICATE']
    text = 'DBMS="sql server"\n' + ''.join(
        name + '="' + value + '"\n' for name, value in zip(names, fields))
    config.write_text(text, encoding='utf-8')
    command = [r, '--vanilla', '--slave', '--file=' + str(repo / 'windows/java-probe-config.R'),
               '--args', str(repo), str(config)]
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, 'Configuration export failed'
    packet = result.stdout.splitlines()
    assert packet[0] == 'FPS_JAVA_PROBE_V1' and len(packet) == 10
    assert [bytes.fromhex(v).decode('utf-8') for v in packet[1:]] == fields
    assert not result.stderr
    config.write_text(text.replace('DB_PORT="1433"', 'DB_PORT="invalid"'), encoding='utf-8')
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 2 and not result.stdout
    assert 'Configuration export failed' in result.stderr
    assert all(v not in result.stderr for v in fields[4:6])
print('PASS: base-R private export preserves UTF-8/configuration and fails without credentials in diagnostics')
