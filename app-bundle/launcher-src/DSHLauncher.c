/*
 * DSHLauncher — CFBundleExecutable for /var/jb/Applications/DSH.app
 *
 * Why a hand-built Mach-O instead of a UIKit app:
 *   SpringBoard only needs a valid, signed arm64 Mach-O as CFBundleExecutable.
 *   We do NOT need UIKit / an iOS SDK: the launcher immediately execv()s the
 *   on-device shell script dsh-app-ui, which (a) makes sure the launchd daemon
 *   is running and (b) opens the DSH Web UI. There is deliberately no
 *   UIApplicationMain loop: DSH itself lives in the daemon, not in this app.
 *
 * Build (x86 Linux, no Xcode needed):
 *   clang --target=arm64-apple-ios16.0 -ffreestanding -fno-stack-protector \
 *         -fno-builtin -O2 -c DSHLauncher.c -o DSHLauncher.o
 *   ld.lld -flavor darwin -arch arm64 -platform_version ios 16.0 16.0 \
 *          -pie -e __main -no_uuid -adhoc_codesign \
 *          -o DSHLauncher DSHLauncher.o
 *   -no_uuid makes the output byte-identical across builds (reproducible).
 *   -adhoc_codesign gives LC_CODE_SIGNATURE so AMFI accepts the binary;
 *   postinst additionally re-signs with on-device ldid + entitlements.
 *
 * arm64 XNU syscall convention: x16 = 0x2000000 (BSD class) + syscall no,
 * args in x0..x5, `svc #0x80`. SYS_execve = 59, SYS_exit = 1.
 */

/* argv/envp for the exec'ed script. All paths absolute: launchd/SpringBoard
 * do NOT give us a usable PATH, and the script must not depend on one. */
static char *const g_argv[] = {
    "/var/jb/usr/bin/dsh-app-ui",
    (char *)0
};
static char *const g_envp[] = {
    "HOME=/var/mobile",
    "PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    "DSH_HOME=/var/jb/var/mobile/.dsh",
    (char *)0
};

__attribute__((noreturn)) static void sys_execve(const char *path,
                                                 char *const *argv,
                                                 char *const *envp) {
    register long x16 asm("x16") = 0x2000000L + 59L; /* SYS_execve */
    register const char *x0 asm("x0") = path;
    register char *const *x1 asm("x1") = argv;
    register char *const *x2 asm("x2") = envp;
    asm volatile("svc #0x80"
                 :
                 : "r"(x16), "r"(x0), "r"(x1), "r"(x2)
                 : "memory");
    for (;;) {}
}

__attribute__((noreturn)) static void sys_exit(int code) {
    register long x16 asm("x16") = 0x2000000L + 1L; /* SYS_exit */
    register long x0 asm("x0") = code;
    asm volatile("svc #0x80" : : "r"(x16), "r"(x0) : "memory");
    for (;;) {}
}

void _main(void) {
    sys_execve(g_argv[0], (char *const *)g_argv, (char *const *)g_envp);
    /* execve only returns on failure */
    sys_exit(78); /* EX_CONFIG */
}
