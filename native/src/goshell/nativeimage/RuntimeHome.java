package goshell.nativeimage;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.ThreadLocalRandom;

/**
 * Resolves the directory that dpt treats as its "executable path".
 *
 * <p>In the original jar this is the directory that contains {@code dpt.jar}, and dpt looks for
 * {@code shell-files/} next to it. In a native image there is no jar, so we embed the payload as
 * resources and materialize it into a cache directory. {@code FileUtils.getExecutablePath()} is
 * substituted at image build time to return the directory produced here.
 *
 * <p>Resolution order:
 * <ol>
 *   <li>{@code GOSHELL_HOME} env var or {@code -Dgoshell.home} system property</li>
 *   <li>the directory containing the native executable, if it has {@code shell-files/}</li>
 *   <li>a per-user cache directory populated from embedded resources</li>
 * </ol>
 */
public final class RuntimeHome {

    private static final String LIST_RESOURCE = "/goshell-files.list";
    private static final String SHELL_FILES = "shell-files";

    private static volatile String resolved;

    private RuntimeHome() {
    }

    public static String ensure() {
        String dir = resolved;
        if (dir != null) {
            return dir;
        }
        synchronized (RuntimeHome.class) {
            if (resolved != null) {
                return resolved;
            }
            resolved = resolve();
            return resolved;
        }
    }

    /**
     * dpt rewrites {@code shell-files/dex/junkcode.dex} on every run. Sharing one directory
     * between concurrent runs (or mutating the user's {@code GOSHELL_HOME}) would make the
     * output non-deterministic, so each process gets a private copy for its lifetime.
     */
    private static String resolve() {
        File sourceRoot = new File(resolveSourceRoot());
        File runDir = createRunDir();
        try {
            copyDirectory(new File(sourceRoot, SHELL_FILES), new File(runDir, SHELL_FILES));
            cleanupStaleRuns(runDir.getParentFile(), runDir);
            Runtime.getRuntime().addShutdownHook(
                    new Thread(() -> deleteRecursively(runDir), "goshell-runtime-cleanup"));
            return runDir.getAbsolutePath();
        } catch (IOException e) {
            // A writable target is not strictly required for a single run; fall back to the
            // shared source directory instead of failing the whole command.
            deleteRecursively(runDir);
            return sourceRoot.getAbsolutePath();
        }
    }

    /** Directory that contains a {@code shell-files/} subtree. */
    private static String resolveSourceRoot() {
        String override = System.getProperty("goshell.home");
        if (isBlank(override)) {
            override = System.getenv("GOSHELL_HOME");
        }
        if (!isBlank(override)) {
            return new File(override).getAbsolutePath();
        }

        File executableDir = executableDir();
        if (executableDir != null && new File(executableDir, SHELL_FILES).isDirectory()) {
            return executableDir.getAbsolutePath();
        }

        List<String> files = readFileList();
        File target = new File(cacheBase(), cacheDirName());
        try {
            if (!isComplete(target, files)) {
                extract(target, files);
            }
            return target.getAbsolutePath();
        } catch (IOException e) {
            File fallback = new File(System.getProperty("java.io.tmpdir", "."),
                    "goshell-" + System.getProperty("user.name", "user") + "/" + cacheDirName());
            try {
                if (!isComplete(fallback, files)) {
                    extract(fallback, files);
                }
                return fallback.getAbsolutePath();
            } catch (IOException second) {
                second.addSuppressed(e);
                throw new IllegalStateException("Cannot extract goshell runtime to " + target
                        + " or " + fallback, second);
            }
        }
    }

    private static File createRunDir() {
        List<File> candidates = new ArrayList<>();
        candidates.add(cacheBase());
        candidates.add(new File(System.getProperty("java.io.tmpdir", "."),
                "goshell-" + System.getProperty("user.name", "user")));
        IOException failure = null;
        for (File base : candidates) {
            try {
                if (!base.isDirectory() && !base.mkdirs() && !base.isDirectory()) {
                    continue;
                }
                return Files.createTempDirectory(base.toPath(), "run-").toFile();
            } catch (IOException e) {
                failure = e;
            }
        }
        throw new IllegalStateException("Cannot create a goshell run directory", failure);
    }

    private static void copyDirectory(File source, File target) throws IOException {
        if (!source.isDirectory()) {
            throw new IOException("Missing shell-files directory: " + source);
        }
        if (!target.isDirectory() && !target.mkdirs() && !target.isDirectory()) {
            throw new IOException("Cannot create directory: " + target);
        }
        // Files.copy preserves POSIX permissions on Linux, so a read-only GOSHELL_HOME
        // would otherwise produce read-only copies that dpt cannot rewrite.
        target.setReadable(true, true);
        target.setWritable(true, true);
        target.setExecutable(true, true);
        File[] children = source.listFiles();
        if (children == null) {
            throw new IOException("Cannot list directory: " + source);
        }
        for (File child : children) {
            File destination = new File(target, child.getName());
            if (child.isDirectory()) {
                copyDirectory(child, destination);
            } else {
                Files.copy(child.toPath(), destination.toPath(),
                        StandardCopyOption.REPLACE_EXISTING);
                destination.setReadable(true, true);
                destination.setWritable(true, true);
            }
        }
    }

    /** Best-effort removal of run directories left behind by killed processes. */
    private static void cleanupStaleRuns(File parent, File current) {
        if (parent == null) {
            return;
        }
        File[] entries = parent.listFiles();
        if (entries == null) {
            return;
        }
        long cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000;
        for (File entry : entries) {
            if (entry.isDirectory() && entry.getName().startsWith("run-")
                    && !entry.equals(current) && entry.lastModified() < cutoff) {
                deleteRecursively(entry);
            }
        }
    }

    private static List<String> readFileList() {
        List<String> files = new ArrayList<>();
        try (InputStream in = RuntimeHome.class.getResourceAsStream(LIST_RESOURCE)) {
            if (in == null) {
                throw new IllegalStateException("Embedded resource missing: " + LIST_RESOURCE);
            }
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            byte[] chunk = new byte[4096];
            int read;
            while ((read = in.read(chunk)) != -1) {
                buffer.write(chunk, 0, read);
            }
            for (String line : new String(buffer.toByteArray(), StandardCharsets.UTF_8).split("\\R")) {
                line = line.trim();
                if (!line.isEmpty() && !line.startsWith("#")) {
                    files.add(line);
                }
            }
        } catch (IOException e) {
            throw new IllegalStateException("Cannot read " + LIST_RESOURCE, e);
        }
        return files;
    }

    private static boolean isComplete(File dir, List<String> files) {
        if (!dir.isDirectory()) {
            return false;
        }
        for (String name : files) {
            File file = new File(dir, name);
            if (!file.isFile() || file.length() == 0) {
                return false;
            }
        }
        return true;
    }

    private static void extract(File target, List<String> files) throws IOException {
        File parent = target.getAbsoluteFile().getParentFile();
        if (parent != null && !parent.isDirectory() && !parent.mkdirs() && !parent.isDirectory()) {
            throw new IOException("Cannot create directory: " + parent);
        }
        File temp = new File(parent, ".tmp-" + target.getName() + "-" + System.nanoTime()
                + "-" + ThreadLocalRandom.current().nextInt(1_000_000));
        deleteRecursively(temp);
        if (!temp.mkdirs()) {
            throw new IOException("Cannot create temporary directory: " + temp);
        }
        try {
            for (String name : files) {
                File out = new File(temp, name);
                File outParent = out.getParentFile();
                if (!outParent.isDirectory() && !outParent.mkdirs() && !outParent.isDirectory()) {
                    throw new IOException("Cannot create directory: " + outParent);
                }
                try (InputStream in = RuntimeHome.class.getResourceAsStream("/" + name)) {
                    if (in == null) {
                        throw new IOException("Embedded resource missing: /" + name);
                    }
                    try (OutputStream os = new FileOutputStream(out)) {
                        copy(in, os);
                    }
                }
            }
            // Publish atomically where the platform allows it.
            if (target.isDirectory()) {
                deleteRecursively(target);
            }
            try {
                Files.move(temp.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE);
            } catch (IOException atomicFailure) {
                // Another process may have won the race, or the filesystem rejects ATOMIC_MOVE.
                if (!isComplete(target, files)) {
                    Files.move(temp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING);
                }
            }
        } finally {
            if (temp.exists()) {
                deleteRecursively(temp);
            }
        }
    }

    private static File cacheBase() {
        String os = System.getProperty("os.name", "").toLowerCase();
        String userHome = System.getProperty("user.home", "");
        if (os.contains("win")) {
            String localAppData = System.getenv("LOCALAPPDATA");
            if (!isBlank(localAppData)) {
                return new File(localAppData, "goshell");
            }
            return new File(userHome, "AppData\\Local\\goshell");
        }
        if (os.contains("mac") || os.contains("darwin")) {
            return new File(userHome, "Library/Caches/goshell");
        }
        String xdg = System.getenv("XDG_CACHE_HOME");
        if (!isBlank(xdg)) {
            return new File(xdg, "goshell");
        }
        return new File(userHome, ".cache/goshell");
    }

    private static File executableDir() {
        try {
            Optional<String> command = ProcessHandle.current().info().command();
            if (command.isPresent()) {
                File exe = new File(command.get());
                File dir = exe.getParentFile();
                if (dir != null) {
                    return dir;
                }
            }
        } catch (Throwable ignored) {
            // Native image may not expose the command on every platform; cache fallback covers it.
        }
        return null;
    }

    /** Version shown by {@code goshell -v}. */
    public static String versionForDisplay() {
        return version();
    }

    private static String version() {
        String value = readTextResource("/goshell-version.txt");
        return value.isEmpty() ? "2.21.0" : sanitize(value);
    }

    /**
     * Cache directory name. The build id changes whenever the embedded shell-files change,
     * so rebuilding dpt with the same version number does not reuse stale extracted assets.
     */
    private static String cacheDirName() {
        String version = version();
        String buildId = sanitize(readTextResource("/goshell-build-id.txt"));
        return buildId.isEmpty() ? "runtime-" + version : "runtime-" + version + "-" + buildId;
    }

    private static String readTextResource(String name) {
        try (InputStream in = RuntimeHome.class.getResourceAsStream(name)) {
            if (in == null) {
                return "";
            }
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            copy(in, buffer);
            return new String(buffer.toByteArray(), StandardCharsets.UTF_8).trim();
        } catch (IOException e) {
            return "";
        }
    }

    private static String sanitize(String value) {
        return value.replaceAll("[^A-Za-z0-9._-]", "_");
    }

    private static void copy(InputStream in, OutputStream out) throws IOException {
        byte[] buffer = new byte[8192];
        int read;
        while ((read = in.read(buffer)) != -1) {
            out.write(buffer, 0, read);
        }
    }

    private static void deleteRecursively(File file) {
        if (!file.exists()) {
            return;
        }
        if (file.isDirectory()) {
            File[] children = file.listFiles();
            if (children != null) {
                for (File child : children) {
                    deleteRecursively(child);
                }
            }
        }
        //noinspection ResultOfMethodCallIgnored
        file.delete();
    }

    private static boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }
}
