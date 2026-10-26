// JDK 17+ source-file launch only: no R, JDBC, database connection or input files.
// Both cases execute the same body and hook. Only the final exit action differs.
public class JvmLifecycleProbe {
    private static String prefix;

    private static void marker(String event) {
        System.out.println(prefix + " event=" + event);
        System.out.flush();
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 2 || !(args[0].equals("return") || args[0].equals("exit"))
                || !args[1].matches("[0-9a-f]{32}")) {
            throw new IllegalArgumentException("Expected return|exit and a diagnostic token");
        }
        String mode = args[0];
        prefix = "JVM_LIFECYCLE token=" + args[1] + " mode=" + mode
            + " pid=" + ProcessHandle.current().pid();
        marker("START");
        System.out.println("JAVA_VERSION=" + System.getProperty("java.version"));
        System.out.println("JAVA_RUNTIME_VERSION=" + System.getProperty("java.runtime.version"));
        System.out.println("JAVA_VENDOR=" + System.getProperty("java.vendor"));
        System.out.println("JAVA_HOME=" + System.getProperty("java.home"));
        System.out.flush();
        if (Runtime.version().feature() < 17) {
            throw new IllegalStateException("This diagnostic requires JDK 17 or newer");
        }
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            marker("SHUTDOWN_HOOK_ENTERED");
            marker("SHUTDOWN_HOOK_FINISHED");
        }, "fps-jvm-lifecycle-shutdown"));
        // Main-thread heartbeats cannot themselves keep the JVM alive at exit.
        for (int tick = 1; tick <= 4; tick++) {
            marker("HEARTBEAT_" + tick);
            Thread.sleep(500);
        }
        marker("BODY_COMPLETE");
        marker(mode.equals("return") ? "RETURN_READY" : "EXIT_REQUESTED");
        if (mode.equals("exit")) System.exit(0);
    }
}
