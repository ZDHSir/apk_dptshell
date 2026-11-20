package goshell.nativeimage;

import com.oracle.svm.core.annotate.Substitute;
import com.oracle.svm.core.annotate.TargetClass;

/**
 * Replaces dpt's jar-relative path with the directory holding our extracted {@code shell-files/}.
 *
 * <p>The original implementation resolves {@code Dpt.class}'s protection domain to a real jar.
 * A native image has no code source URL, which would leave dpt looking for {@code /shell-files}
 * at the filesystem root. The substituted method keeps every caller working unchanged.
 */
@TargetClass(className = "com.luoye.dpt.util.FileUtils")
public final class FileUtilsSubstitution {

    @Substitute
    public static String getExecutablePath() {
        return RuntimeHome.ensure();
    }
}
