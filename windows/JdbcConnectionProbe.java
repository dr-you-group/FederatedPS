// Run with the installed JDK 17 source-file launcher. No javac/build/install.
// Reads the same selected JAR/configuration via stdin; no secrets in arguments,
// output, result cells or files. Queries only SELECT 1 and bounded CARE_SITE rows.
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.Driver;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.Instant;
import java.lang.reflect.InvocationTargetException;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.atomic.AtomicBoolean;

public class JdbcConnectionProbe {
    private static volatile String phase = "initializing";
    private static volatile long phaseStart = System.nanoTime();
    private static String[] config;
    private static final AtomicBoolean complete = new AtomicBoolean(false);
    private static final AtomicBoolean firstFailureLogged = new AtomicBoolean(false);
    // A separate raw stderr path keeps liveness evidence independent of the
    // normal PrintStream monitor, Instant formatting and JDBC conversion.
    private static final FileOutputStream heartbeatOutput = new FileOutputStream(FileDescriptor.err);
    private static final byte[] heartbeatBytes = "JAVA_HEARTBEAT\n".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] timeoutBytes = "JAVA_WATCHDOG_TIMEOUT_RAW\n".getBytes(StandardCharsets.US_ASCII);

    private static void raw(byte[] bytes) {
        try { heartbeatOutput.write(bytes); heartbeatOutput.flush(); } catch (Throwable ignored) { }
    }

    private static void log(String text) {
        System.out.println(Instant.now() + " " + text);
        System.out.flush();
    }
    private static void start(String name) {
        phase = name;
        phaseStart = System.nanoTime();
        log("START " + name);
    }
    private static void end() {
        log("DONE " + phase + " elapsed_ms=" + ((System.nanoTime() - phaseStart) / 1_000_000));
    }
    private static String redact(String text) {
        if (text == null) return "";
        if (config != null) {
            // User/password must never be printed, even inside a driver error.
            String[] secrets = new String[] {config[4], config[5]};
            Arrays.sort(secrets, Comparator.nullsLast(Comparator.comparingInt(String::length).reversed()));
            for (String secret : secrets) {
                if (secret != null && !secret.isEmpty()) text = text.replace(secret, "[REDACTED]");
            }
        }
        return text.replace('\r', ' ').replace('\n', ' ');
    }
    private static void failure(Throwable error) {
        while (error instanceof InvocationTargetException && error.getCause() != null) error = error.getCause();
        if (!firstFailureLogged.compareAndSet(false, true)) {
            log("SECONDARY_FAILURE class=" + error.getClass().getName() + " " + redact(error.getMessage()));
            return;
        }
        log("FIRST_FAILURE phase=" + phase + " class=" + error.getClass().getName());
        log("ERROR " + redact(error.getMessage()));
        if (error instanceof SQLException) {
            SQLException sql = (SQLException) error;
            log("SQLSTATE=" + sql.getSQLState() + " vendorCode=" + sql.getErrorCode());
        }
        for (StackTraceElement frame : error.getStackTrace()) System.out.println("    at " + frame);
        System.out.flush();
    }
    private static void dumpThreads() {
        log("JAVA_THREAD_DUMP_BEGIN");
        for (Map.Entry<Thread, StackTraceElement[]> entry : Thread.getAllStackTraces().entrySet()) {
            Thread thread = entry.getKey();
            log("THREAD id=" + thread.getId() + " name=" + thread.getName() + " state=" + thread.getState());
            for (StackTraceElement frame : entry.getValue()) System.out.println("    at " + frame);
        }
        log("JAVA_THREAD_DUMP_END");
    }
    private static void watchdog(int totalSeconds, int phaseSeconds) {
        long begun = System.nanoTime();
        raw(heartbeatBytes); // Preinitialize this path before configuration/JDBC.
        Thread heartbeat = new Thread(() -> {
            while (!complete.get()) {
                try { Thread.sleep(5000); } catch (InterruptedException ignored) { return; }
                raw(heartbeatBytes);
            }
        }, "fps-java-probe-heartbeat");
        heartbeat.setDaemon(true);
        heartbeat.start();
        Thread guard = new Thread(() -> {
            while (!complete.get()) {
                long now = System.nanoTime();
                if ((now - begun) / 1_000_000_000L >= totalSeconds ||
                    (now - phaseStart) / 1_000_000_000L >= phaseSeconds) {
                    raw(timeoutBytes);
                    log("JAVA_WATCHDOG_TIMEOUT phase=" + phase);
                    dumpThreads();
                    System.out.flush();
                    System.err.flush();
                    Runtime.getRuntime().halt(124);
                }
                try { Thread.sleep(200); } catch (InterruptedException ignored) { return; }
            }
        }, "fps-java-probe-watchdog");
        guard.setDaemon(true);
        guard.start();
    }
    private static String fromHex(String value) {
        if ((value.length() & 1) != 0 || !value.matches("[0-9a-fA-F]*"))
            throw new IllegalArgumentException("Invalid private input packet");
        byte[] bytes = new byte[value.length() / 2];
        for (int i = 0; i < bytes.length; i++) bytes[i] = (byte) Integer.parseInt(value.substring(i * 2, i * 2 + 2), 16);
        return new String(bytes, StandardCharsets.UTF_8);
    }
    private static void readConfig() throws Exception {
        BufferedReader input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.US_ASCII));
        if (!"FPS_JAVA_PROBE_V1".equals(input.readLine())) throw new IllegalArgumentException("Missing private input header");
        config = new String[9];
        for (int i = 0; i < config.length; i++) {
            String line = input.readLine();
            if (line == null || line.length() > 131072) throw new IllegalArgumentException("Incomplete private input packet");
            config[i] = fromHex(line);
        }
        if (input.readLine() != null) throw new IllegalArgumentException("Unexpected private input field");
        if (!config[1].matches("[A-Za-z0-9_.-]+") || !config[2].matches("[0-9]+") ||
            Integer.parseInt(config[2]) < 1 || Integer.parseInt(config[2]) > 65535 ||
            !config[3].matches("[A-Za-z_][A-Za-z0-9_]*") ||
            !config[6].matches("[A-Za-z_][A-Za-z0-9_]*\\.[A-Za-z_][A-Za-z0-9_]*") ||
            !config[7].matches("true|false") || !config[8].matches("true|false"))
            throw new IllegalArgumentException("Invalid connection configuration");
    }
    private static void query(Connection connection, int site, int queryTimeout, String buffering, String mode) throws Throwable {
        String label = site == 0 ? "self-check" : site < 0 ? "synthetic-text" : "CARE_SITE site_id=" + site;
        Statement statement = null;
        ResultSet result = null;
        Throwable first = null;
        int originalTimeout = 0;
        boolean changedTimeout = false;
        boolean checked = false;
        try {
            start(label + " Connection.getNetworkTimeout"); originalTimeout = connection.getNetworkTimeout(); end();
            start(label + " Connection.setNetworkTimeout"); connection.setNetworkTimeout(null, (queryTimeout + 15) * 1000); changedTimeout = true; end();
            start(label + " Connection.createStatement");
            statement = connection.createStatement(2003, 1007); end();
            start(label + " Statement.setResponseBuffering=" + buffering);
            statement.getClass().getMethod("setResponseBuffering", String.class).invoke(statement, buffering); end();
            start(label + " Statement.setQueryTimeout"); statement.setQueryTimeout(queryTimeout); end();
            String sql;
            if (site == 0) sql = "SELECT CAST(1 AS INT) AS ok, @@SPID AS session_id";
            else if (site < 0) sql = "SELECT CAST(1 AS INT) AS probe_id, CAST('FPS_ASCII' AS VARCHAR(32)) AS ascii_text, " +
                "CAST(N'\uD55C\uAE00' AS NVARCHAR(32)) AS unicode_text, " +
                "CAST(N'\uD55C\uAE00' COLLATE Korean_Wansung_CI_AS AS VARCHAR(32)) AS korean_varchar";
            else sql = "SELECT TOP (2) care_site_id" +
                (mode.equals("care-site-text") ? ", care_site_name, care_site_source_value" : "") +
                " FROM " + config[6] + ".CARE_SITE WHERE care_site_id = " + site;
            start(label + " Statement.executeQuery"); result = statement.executeQuery(sql); end();
            int rows = 0;
            while (true) {
                start(label + " ResultSet.next"); boolean more = result.next(); end();
                if (!more) break;
                if (++rows > 2) throw new SQLException("Small probe returned more than two rows");
                start(label + " ResultSet.getInt row=" + rows + " column=1");
                int id = result.getInt(1); end();
                start(label + " ResultSet.wasNull row=" + rows + " column=1"); boolean nullId = result.wasNull(); end();
                if (nullId || id != (site <= 0 ? 1 : site)) throw new SQLException("Unexpected self-check/site ID");
                if (site == 0) {
                    start(label + " ResultSet.getInt column=2");
                    int spid = result.getInt(2); end();
                    start(label + " ResultSet.wasNull row=" + rows + " column=2"); boolean nullSpid = result.wasNull(); end();
                    if (nullSpid || spid <= 0) throw new SQLException("Missing SQL Server session ID");
                    log("SQL_SERVER_SPID=" + spid);
                } else for (int column = 2; column <= (site < 0 ? 4 : mode.equals("care-site-text") ? 3 : 1); column++) {
                    start(label + " ResultSet.getMetaData column=" + column);
                    ResultSetMetaData metadata = result.getMetaData(); end();
                    start(label + " ResultSetMetaData.getColumnType column=" + column);
                    int jdbcType = metadata.getColumnType(column); end();
                    start(label + " ResultSetMetaData.getPrecision column=" + column);
                    int precision = metadata.getPrecision(column); end();
                    log("COLUMN_METADATA column=" + column + " jdbc_type=" + jdbcType + " precision=" + precision);
                    start(label + " ResultSet.getString row=" + rows + " column=" + column);
                    String value = result.getString(column); end();
                    start(label + " ResultSet.wasNull row=" + rows + " column=" + column);
                    boolean nullText = result.wasNull(); end();
                    if (site < 0 && (nullText || !value.equals(column == 2 ? "FPS_ASCII" : "\uD55C\uAE00")))
                        throw new SQLException("Unexpected synthetic string conversion result; values omitted");
                }
            }
            if (rows != 1) throw new SQLException("Expected exactly one self-check/CARE_SITE row");
            start(label + " Statement.getMoreResults"); boolean extra = statement.getMoreResults(); end();
            start(label + " Statement.getUpdateCount"); int updated = statement.getUpdateCount(); end();
            if (extra || updated != -1) throw new SQLException("Unexpected extra result after bounded query");
            checked = true;
        } catch (Throwable error) {
            first = error; failure(error); throw error;
        } finally {
            Throwable cleanup = null;
            try { if (result != null) { start(label + " ResultSet.close"); result.close(); end(); } }
            catch (Throwable error) { cleanup = error; if (first == null) failure(error); }
            try { if (statement != null) { start(label + " Statement.close"); statement.close(); end(); } }
            catch (Throwable error) { if (cleanup == null) { cleanup = error; if (first == null) failure(error); } }
            try { if (changedTimeout) { start(label + " Connection.restoreNetworkTimeout"); connection.setNetworkTimeout(null, originalTimeout); end(); } }
            catch (Throwable error) { if (cleanup == null) { cleanup = error; if (first == null) failure(error); } }
            if (checked && cleanup == null) {
                try {
                    start(label + " Connection.isClosed"); boolean closed = connection.isClosed(); end();
                    if (closed) throw new SQLException("Connection closed during probe cleanup");
                } catch (Throwable error) { cleanup = error; if (first == null) failure(error); }
            }
            if (cleanup != null) {
                if (first == null) throw cleanup;
                log("CLEANUP_FAILURE " + cleanup.getClass().getName() + " " + redact(cleanup.getMessage()));
            }
        }
        log("CHECK_OK " + label);
    }
    public static void main(String[] args) {
        Connection connection = null;
        int code = 2;
        try {
            if (args.length != 5) throw new IllegalArgumentException("Expected timeout, total deadline, buffering, site IDs and probe mode");
            int queryTimeout = Integer.parseInt(args[0]);
            int totalTimeout = Integer.parseInt(args[1]);
            if (queryTimeout < 1 || queryTimeout > 300 || totalTimeout < 1 || totalTimeout > 900 ||
                !(args[2].equals("full") || args[2].equals("adaptive")) ||
                !(args[4].equals("care-site-id") || args[4].equals("care-site-text") || args[4].equals("synthetic-text")))
                throw new IllegalArgumentException("Invalid probe limits/mode");
            watchdog(totalTimeout, queryTimeout + 15);
            start("Read private configuration"); readConfig(); end();
            Class<?> driverClass = Class.forName("com.microsoft.sqlserver.jdbc.SQLServerDriver");
            Path actualJar = Path.of(driverClass.getProtectionDomain().getCodeSource().getLocation().toURI()).toRealPath();
            if (!actualJar.equals(Path.of(config[0]).toRealPath())) throw new IllegalStateException("Unexpected JDBC class source");
            Driver driver = (Driver) driverClass.getDeclaredConstructor().newInstance();
            log("JDBC_ACTIVE=" + actualJar);
            log("JAVA_VERSION=" + System.getProperty("java.version") + " JAVA_VENDOR=" + System.getProperty("java.vendor"));
            log("PROBE_MODE=" + args[4]);
            log("PROFILE queryTimeout=" + queryTimeout + " socketTimeout=" + ((queryTimeout + 15) * 1000) +
                " loginTimeout=30 cancelQueryTimeout=10 selectMethod=direct responseBuffering=" + args[2] +
                " encrypt=" + config[7] + " trustServerCertificate=" + config[8]);
            String url = "jdbc:sqlserver://" + config[1] + ";port=" + config[2] + ";databaseName=" + config[3] +
                ";encrypt=" + config[7] + ";trustServerCertificate=" + config[8] +
                ";selectMethod=direct;responseBuffering=adaptive;loginTimeout=30;cancelQueryTimeout=10;queryTimeout=7200;socketTimeout=" +
                ((queryTimeout + 15) * 1000);
            Properties credentials = new Properties();
            credentials.setProperty("user", config[4]); credentials.setProperty("password", config[5]);
            start("Connection.connect"); connection = driver.connect(url, credentials); end();
            if (connection == null) throw new SQLException("Driver did not accept SQL Server URL");
            start("Connection.getMetaData"); String version = connection.getMetaData().getDriverVersion(); end();
            log("CONNECTED_DRIVER_VERSION=" + version);
            query(connection, 0, queryTimeout, args[2], args[4]);
            if (args[4].equals("synthetic-text")) query(connection, -1, queryTimeout, args[2], args[4]);
            else for (String value : args[3].split(",")) {
                int site = Integer.parseInt(value);
                if (site < 1) throw new IllegalArgumentException("Invalid site ID");
                query(connection, site, queryTimeout, args[2], args[4]);
            }
            start("Connection.close"); connection.close(); connection = null; end();
            log("CHECKS_COMPLETE: independent Java checks and explicit close finished; waiting for process exit");
            code = 0;
        } catch (Throwable error) {
            failure(error);
        } finally {
            if (connection != null) {
                try { start("Connection.close after failure"); connection.close(); end(); }
                catch (Throwable error) { log("CLEANUP_FAILURE " + error.getClass().getName() + " " + redact(error.getMessage())); }
            }
        }
        // The external launcher confirms exit: JVM shutdown may stop daemon
        // threads before the native process exits, so a heartbeat/watchdog is
        // not guaranteed to survive System.exit. Completed checks are separate
        // from successful process shutdown.
        start("JVM termination System.exit(" + code + ")");
        System.exit(code);
    }
}
