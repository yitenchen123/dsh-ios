/*
 * dsh-app-helper — tiny setuid-root helper for the DSH APP.
 *
 * The app runs as mobile and cannot `launchctl bootstrap system/...` itself.
 * This helper is installed root:wheel 4755 and runs exactly one fixed command:
 *   dsh-app-ctl ensure
 * which bootstraps/kickstarts the launchd daemon when it is not running.
 * It accepts no arguments and cannot run arbitrary commands.
 */
#include <unistd.h>
#include <stdio.h>

int main(void) {
    if (setgid(0) != 0 || setuid(0) != 0) {
        return 78;
    }
    execl("/var/jb/bin/sh", "sh", "-c",
          "/var/jb/usr/bin/dsh-app-ctl ensure >/dev/null 2>&1", (char *)0);
    return 78;
}
