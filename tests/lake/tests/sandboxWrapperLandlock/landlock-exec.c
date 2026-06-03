/*
A standalone Landlock "exec under a write-only policy" helper.

This is a faithful, self-contained port of the `lean_sandbox_exec` function that
the `lake build --sandbox` PR (#13940) compiles *into the lean runtime*
(`src/runtime/landlock.cpp`). The point of the port is to show that the same
write-isolation primitive can live entirely *outside* Lean/Lake, behind the
`LAKE_WRAPPED_EXEC` wrapper -- with no changes to the compiler, build system, or
runtime.

Usage:
    landlock-exec (--rw <dir>)* -- <prog> <args...>

It installs a Landlock policy that handles only *write-class* filesystem access
rights and grants them beneath each --rw directory only; read/execute/ioctl are
left unhandled and therefore unrestricted (the PR's "write-only" policy). It
closes inherited fds first (essential: Landlock does not restrict already-open
files), requires Landlock ABI >= 3 (Linux 6.2, for TRUNCATE handling), and runs
the inner program in its own process group, SIGKILLing the group afterwards so a
backgrounded writer cannot mutate a scratch artifact after we return.

The Landlock ABI constants and syscall numbers are defined here rather than
pulled from system headers, exactly as in the runtime version, since build hosts
frequently have userspace headers older than the running kernel.
*/

#include <cstdio>
#include <cstring>
#include <cstdlib>

#if defined(__linux__)

#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>
#include <stdint.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <sys/types.h>

#ifndef PR_SET_NO_NEW_PRIVS
#define PR_SET_NO_NEW_PRIVS 38
#endif

#ifndef __NR_landlock_create_ruleset
#define __NR_landlock_create_ruleset 444
#endif
#ifndef __NR_landlock_add_rule
#define __NR_landlock_add_rule 445
#endif
#ifndef __NR_landlock_restrict_self
#define __NR_landlock_restrict_self 446
#endif
#ifndef __NR_close_range
#define __NR_close_range 436
#endif

#define LL_CREATE_RULESET_VERSION (1U << 0)

#define LL_ACCESS_FS_EXECUTE     (1ULL << 0)
#define LL_ACCESS_FS_WRITE_FILE  (1ULL << 1)
#define LL_ACCESS_FS_READ_FILE   (1ULL << 2)
#define LL_ACCESS_FS_READ_DIR    (1ULL << 3)
#define LL_ACCESS_FS_REMOVE_DIR  (1ULL << 4)
#define LL_ACCESS_FS_REMOVE_FILE (1ULL << 5)
#define LL_ACCESS_FS_MAKE_CHAR   (1ULL << 6)
#define LL_ACCESS_FS_MAKE_DIR    (1ULL << 7)
#define LL_ACCESS_FS_MAKE_REG    (1ULL << 8)
#define LL_ACCESS_FS_MAKE_SOCK   (1ULL << 9)
#define LL_ACCESS_FS_MAKE_FIFO   (1ULL << 10)
#define LL_ACCESS_FS_MAKE_BLOCK  (1ULL << 11)
#define LL_ACCESS_FS_MAKE_SYM    (1ULL << 12)
#define LL_ACCESS_FS_REFER       (1ULL << 13)  // ABI >= 2
#define LL_ACCESS_FS_TRUNCATE    (1ULL << 14)  // ABI >= 3

#define LL_RULE_PATH_BENEATH 1

namespace {

struct ll_ruleset_attr {
    uint64_t handled_access_fs;
};

struct ll_path_beneath_attr {
    uint64_t allowed_access;
    int32_t  parent_fd;
} __attribute__((packed));

inline long ll_create_ruleset(const ll_ruleset_attr * attr, size_t size, uint32_t flags) {
    return syscall(__NR_landlock_create_ruleset, attr, size, flags);
}

inline long ll_add_rule(int ruleset_fd, const ll_path_beneath_attr * attr, uint32_t flags) {
    return syscall(__NR_landlock_add_rule, ruleset_fd, LL_RULE_PATH_BENEATH, attr, flags);
}

inline long ll_restrict_self(int ruleset_fd, uint32_t flags) {
    return syscall(__NR_landlock_restrict_self, ruleset_fd, flags);
}

void fail(const char * msg) {
    fprintf(stderr, "landlock-exec: %s\n", msg);
}

void fail_errno(const char * msg) {
    fprintf(stderr, "landlock-exec: %s: %s\n", msg, strerror(errno));
}

// Close every file descriptor except stdio (0/1/2). Essential, not hygiene:
// Landlock does not restrict files that were already open before the policy is
// applied, so an inherited writable fd into the build tree would defeat the
// sandbox entirely (man landlock.7).
void close_inherited_fds() {
    long r = syscall(__NR_close_range, (unsigned)3, ~0U, 0u);
    if (r == 0)
        return;
    DIR * d = opendir("/proc/self/fd");
    if (d == nullptr) {
        for (int fd = 3; fd < 1024; fd++)
            close(fd);
        return;
    }
    int dir_fd = dirfd(d);
    struct dirent * ent;
    while ((ent = readdir(d)) != nullptr) {
        if (ent->d_name[0] < '0' || ent->d_name[0] > '9')
            continue;
        int fd = atoi(ent->d_name);
        if (fd >= 3 && fd != dir_fd)
            close(fd);
    }
    closedir(d);
}

} // namespace

int main(int argc, char ** argv) {
    // Layout: argv[0] = landlock-exec
    //         ("--rw" <dir>)*  "--"  <prog> <args...>
    char * rw_dirs[256];
    int num_rw = 0;
    int i = 1;
    for (; i < argc; i++) {
        if (strcmp(argv[i], "--rw") == 0) {
            if (i + 1 >= argc) { fail("--rw requires a directory argument"); return 1; }
            if (num_rw >= 256) { fail("too many --rw directories"); return 1; }
            rw_dirs[num_rw++] = argv[++i];
        } else if (strcmp(argv[i], "--") == 0) {
            i++;
            break;
        } else {
            fail("unexpected argument before '--' (expected --rw <dir> or --)");
            return 1;
        }
    }
    if (i >= argc) { fail("missing '-- <prog> <args...>'"); return 1; }
    char ** child_argv = &argv[i];

    pid_t pid = fork();
    if (pid < 0) {
        fail_errno("fork failed");
        return 1;
    }
    if (pid == 0) {
        // --- Child: new process group, sandbox, then exec the inner program. ---
        setpgid(0, 0);

        // 1. Drop inherited file descriptors.
        close_inherited_fds();

        // 2. No new privileges, required for unprivileged Landlock.
        if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
            fail_errno("prctl(PR_SET_NO_NEW_PRIVS) failed");
            _exit(1);
        }

        // 3. Require Landlock ABI >= 3 (TRUNCATE handling).
        long abi = ll_create_ruleset(nullptr, 0, LL_CREATE_RULESET_VERSION);
        if (abi < 0) {
            fail_errno("Landlock is not available (landlock_create_ruleset)");
            _exit(1);
        }
        if (abi < 3) {
            fprintf(stderr, "landlock-exec: Landlock ABI %ld too old; "
                            "version >= 3 (Linux 6.2) is required\n", abi);
            _exit(1);
        }

        // 4. Handle only write-class filesystem access rights.
        uint64_t handled =
            LL_ACCESS_FS_WRITE_FILE  |
            LL_ACCESS_FS_REMOVE_DIR  |
            LL_ACCESS_FS_REMOVE_FILE |
            LL_ACCESS_FS_MAKE_CHAR   |
            LL_ACCESS_FS_MAKE_DIR    |
            LL_ACCESS_FS_MAKE_REG    |
            LL_ACCESS_FS_MAKE_SOCK   |
            LL_ACCESS_FS_MAKE_FIFO   |
            LL_ACCESS_FS_MAKE_BLOCK  |
            LL_ACCESS_FS_MAKE_SYM    |
            LL_ACCESS_FS_REFER       |   // ABI >= 2
            LL_ACCESS_FS_TRUNCATE;       // ABI >= 3

        ll_ruleset_attr attr = { handled };
        int ruleset_fd = (int)ll_create_ruleset(&attr, sizeof(attr), 0);
        if (ruleset_fd < 0) {
            fail_errno("landlock_create_ruleset failed");
            _exit(1);
        }

        // 5. Grant the handled write rights beneath each --rw directory only.
        for (int k = 0; k < num_rw; k++) {
            const char * dir = rw_dirs[k];
            int dfd = open(dir, O_PATH | O_CLOEXEC);
            if (dfd < 0) {
                fprintf(stderr, "landlock-exec: cannot open --rw directory '%s': %s\n",
                        dir, strerror(errno));
                _exit(1);
            }
            ll_path_beneath_attr pb = { handled, dfd };
            if (ll_add_rule(ruleset_fd, &pb, 0) != 0) {
                fprintf(stderr, "landlock-exec: landlock_add_rule for '%s' failed: %s\n",
                        dir, strerror(errno));
                _exit(1);
            }
            close(dfd);
        }

        // 5b. Always permit writing to /dev/null and /dev/full.
        static const char * const writable_devs[] = { "/dev/null", "/dev/full" };
        for (unsigned di = 0; di < sizeof(writable_devs) / sizeof(writable_devs[0]); di++) {
            int fd = open(writable_devs[di], O_PATH | O_CLOEXEC);
            if (fd < 0)
                continue;
            ll_path_beneath_attr pb = { LL_ACCESS_FS_WRITE_FILE | LL_ACCESS_FS_TRUNCATE, fd };
            ll_add_rule(ruleset_fd, &pb, 0);
            close(fd);
        }

        // 6. Enforce, then exec; the domain is inherited across execve.
        if (ll_restrict_self(ruleset_fd, 0) != 0) {
            fail_errno("landlock_restrict_self failed");
            _exit(1);
        }
        close(ruleset_fd);

        execvp(child_argv[0], child_argv);
        fprintf(stderr, "landlock-exec: failed to exec '%s': %s\n",
                child_argv[0], strerror(errno));
        _exit(127);
    }

    // --- Parent: supervise. Not under Landlock, in a different process group. ---
    setpgid(pid, pid);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) { /* retry */ }

    kill(-pid, SIGKILL);
    while (waitpid(-pid, nullptr, WNOHANG) > 0) { /* reap */ }

    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    if (WIFSIGNALED(status))
        return 128 + WTERMSIG(status);
    return 1;
}

#else // !__linux__

int main(int, char **) {
    fprintf(stderr, "landlock-exec: filesystem sandboxing is only supported on "
                    "Linux (Landlock)\n");
    return 1;
}

#endif
