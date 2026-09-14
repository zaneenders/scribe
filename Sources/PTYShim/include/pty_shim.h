#ifndef SCRIBE_PTY_SHIM_H
#define SCRIBE_PTY_SHIM_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif
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
int scribe_dup_cloexec(int fd, int *duplicate_fd);
int scribe_set_nonblocking(int fd, int enabled);
int scribe_wait_until_exited(pid_t child_pid);

#ifdef __cplusplus
}
#endif

#endif
