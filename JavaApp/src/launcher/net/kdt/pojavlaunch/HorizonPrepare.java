package net.kdt.pojavlaunch;

import java.io.File;
import java.io.FileOutputStream;
import java.io.PrintStream;
import java.lang.reflect.InvocationTargetException;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Prepares Horizon's 26.3 files on the device. iOS starts no processes, so Horizon's preparer
 * (horizon_ios_prepare in libhorizon_ios) runs here, through the native run(), and sends each
 * Java task it would give a new JVM to task(): every classpath gets a class loader of its own.
 */
public final class HorizonPrepare {
    static {
        System.load(System.getenv("BUNDLE_PATH") + "/AngelAuraAmethyst");
    }

    // Natives/horizon/HorizonSetup.m
    private static native int run();

    /** The exporter workers by name: their class loader, PrepareWorker in it, and its tag reset. */
    private static final Map<String, Object[]> workers = new HashMap<String, Object[]>();

    public static void main(String[] args) {
        int status = run();
        System.out.println(status == 0
            ? "Horizon is ready. AMADORA closes now: open it again and press Play on a Horizon instance."
            : "Horizon's setup failed; the lines above say why.");
        System.exit(status);
    }

    /** One task (horizon_prepare::java::InProcess): "" when it worked, else what went wrong. */
    public static String task(String[] t) {
        PrintStream out = System.out, err = System.err;
        ClassLoader context = Thread.currentThread().getContextClassLoader();
        try {
            if (t[0].equals("worker")) return worker(t);
            if (t[0].equals("close")) {
                Object[] worker = workers.remove(t[1]);
                if (worker != null) ((URLClassLoader) worker[0]).close();
                return "";
            }
            if (t[0].equals("java")) return java(t);
            return "Unknown task " + t[0];
        } catch (Throwable e) {
            Throwable cause = e instanceof InvocationTargetException && e.getCause() != null ? e.getCause() : e;
            cause.printStackTrace();
            return String.valueOf(cause);
        } finally {
            System.setOut(out);
            System.setErr(err);
            Thread.currentThread().setContextClassLoader(context);
        }
    }

    // ["worker", name, log, classpath, main, args...]
    private static String worker(String[] t) throws Exception {
        Object[] worker = workers.get(t[1]);
        if (worker == null) {
            URLClassLoader loader = loader(t[3]);
            Thread.currentThread().setContextClassLoader(loader);
            logTo(t[2]); // vanilla's bootstrap output, ahead of the first task's
            Class<?> type = loader.loadClass("dev.horizonlab.parity.PrepareWorker");
            worker = new Object[] {loader, type, type.getMethod("init").invoke(null)};
            workers.put(t[1], worker);
        }
        Thread.currentThread().setContextClassLoader((ClassLoader) worker[0]);
        return (String) ((Class<?>) worker[1])
            .getMethod("task", String.class, String.class, String[].class, Runnable.class)
            .invoke(null, t[2], t[4], Arrays.copyOfRange(t, 5, t.length), worker[2]);
    }

    // ["java", cwd, log, java's own arguments...]: -X options don't apply here, -D ones do while it runs
    private static String java(String[] t) throws Exception {
        String classpath = null, main = null;
        Map<String, String> properties = new HashMap<String, String>();
        int i = 3;
        for (; i < t.length && main == null; i++) {
            String arg = t[i];
            if (arg.equals("-cp") || arg.equals("-classpath")) {
                classpath = t[++i];
            } else if (arg.startsWith("-D")) {
                int split = arg.indexOf('=');
                properties.put(arg.substring(2, split < 0 ? arg.length() : split), split < 0 ? "" : arg.substring(split + 1));
            } else if (arg.equals("-jar")) {
                return "A -jar task can't run in AMADORA's Java";
            } else if (!arg.startsWith("-")) {
                main = arg;
            }
        }
        if (classpath == null || main == null) return "No classpath or main class in " + Arrays.toString(t);
        Map<String, String> previous = new HashMap<String, String>();
        for (Map.Entry<String, String> property : properties.entrySet()) {
            previous.put(property.getKey(), System.setProperty(property.getKey(), property.getValue()));
        }
        URLClassLoader loader = loader(classpath);
        try {
            Thread.currentThread().setContextClassLoader(loader);
            logTo(t[2]);
            loader.loadClass(main).getMethod("main", String[].class)
                .invoke(null, (Object) Arrays.copyOfRange(t, i, t.length));
            return "";
        } finally {
            loader.close();
            for (Map.Entry<String, String> property : previous.entrySet()) {
                if (property.getValue() == null) System.clearProperty(property.getKey());
                else System.setProperty(property.getKey(), property.getValue());
            }
        }
    }

    private static void logTo(String path) throws Exception {
        if (path.isEmpty()) return;
        PrintStream log = new PrintStream(new FileOutputStream(path, true), true, "UTF-8");
        System.setOut(log);
        System.setErr(log);
    }

    /** A loader of its own for a classpath, above Java's platform classes and not the launcher's. */
    private static URLClassLoader loader(String classpath) throws Exception {
        List<URL> urls = new ArrayList<URL>();
        for (String entry : classpath.split(File.pathSeparator)) {
            if (!entry.isEmpty()) urls.add(new File(entry).toURI().toURL());
        }
        ClassLoader platform = (ClassLoader) ClassLoader.class.getMethod("getPlatformClassLoader").invoke(null);
        return new URLClassLoader(urls.toArray(new URL[0]), platform);
    }
}
