package goshell.nativeimage;

import com.oracle.svm.core.annotate.Substitute;
import com.oracle.svm.core.annotate.TargetClass;

/**
 * {@code Package.getImplementationVersion()} is null in a native image, so {@code -v} would
 * otherwise report "unknown". Keep the CLI output identical to the jar build.
 */
@TargetClass(className = "com.luoye.dpt.Dpt")
public final class DptSubstitution {

    @Substitute
    public static String getVersion() {
        return RuntimeHome.versionForDisplay();
    }
}
