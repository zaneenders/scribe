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

#ifdef __cplusplus
}
#endif

#endif
