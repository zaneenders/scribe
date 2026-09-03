#ifndef SCRIBE_PTY_SHIM_H
#define SCRIBE_PTY_SHIM_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opens a PTY and launches argv[0] as the session leader with the slave PTY as
// its controlling terminal and standard streams. Returns 0 on success or an
// errno value on failure.
int scribe_pty_spawn(
    const char *path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int columns,
    int rows,
    int *master_fd,
    pid_t *child_pid);

int scribe_pty_resize(int master_fd, int columns, int rows);

// Atomically duplicates a descriptor with close-on-exec enabled. Returns 0 on
// success or an errno value on failure.
int scribe_dup_cloexec(int fd, int *duplicate_fd);

// Waits until child_pid has exited without reaping it. The caller must
// subsequently call waitpid(2). Returns 0 on success or an errno value.
int scribe_wait_until_exited(pid_t child_pid);

#ifdef __cplusplus
}
#endif

#endif
