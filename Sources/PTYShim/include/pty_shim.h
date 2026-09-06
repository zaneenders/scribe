#ifndef SCRIBE_PTY_SHIM_H
#define SCRIBE_PTY_SHIM_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opens a PTY and launches argv[0] as the leader of an isolated session. A
// small direct-child supervisor owns and reaps the session leader. It watches a
// control pipe for explicit close and its parent PID for abrupt caller death,
// then kills every process in the terminal session. The supervisor's exit status
// mirrors the terminal leader's status.
//
// supervisor_pid is the caller's direct child and must be waited for.
// process_group_pid identifies the spawned terminal session and may be passed
// to kill(2) as a negative PID. Closing control_fd requests unconditional
// cleanup of that process group. status_fd yields the terminal leader's raw
// waitpid(2) status before reaching EOF.
int scribe_pty_spawn(
    const char *path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int columns,
    int rows,
    int *master_fd,
    pid_t *supervisor_pid,
    pid_t *process_group_pid,
    int *control_fd,
    int *status_fd);

int scribe_pty_resize(int master_fd, int columns, int rows);

// Atomically duplicates a descriptor with close-on-exec enabled. Returns 0 on
// success or an errno value on failure.
int scribe_dup_cloexec(int fd, int *duplicate_fd);

// Enables or disables nonblocking I/O on a descriptor. Returns 0 on success or
// an errno value on failure.
int scribe_set_nonblocking(int fd, int enabled);

#ifdef __cplusplus
}
#endif

#endif
