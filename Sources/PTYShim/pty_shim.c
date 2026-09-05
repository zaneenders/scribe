#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include "pty_shim.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

static struct winsize scribe_winsize(int columns, int rows) {
  struct winsize size = {0};
  size.ws_col = (unsigned short)(columns > 0 ? columns : 1);
  size.ws_row = (unsigned short)(rows > 0 ? rows : 1);
  return size;
}

int scribe_pty_resize(int master_fd, int columns, int rows) {
  struct winsize size = scribe_winsize(columns, rows);
  if (ioctl(master_fd, TIOCSWINSZ, &size) == -1) return errno;
  return 0;
}

int scribe_dup_cloexec(int fd, int *duplicate_fd) {
  int duplicate;
  do {
    duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0);
  } while (duplicate == -1 && errno == EINTR);
  if (duplicate == -1) return errno;
  *duplicate_fd = duplicate;
  return 0;
}

int scribe_wait_until_exited(pid_t child_pid) {
  siginfo_t info;
  int result;
  do {
    result = waitid(P_PID, (id_t)child_pid, &info, WEXITED | WNOWAIT);
  } while (result == -1 && errno == EINTR);
  return result == -1 ? errno : 0;
}

int scribe_pty_spawn(
    const char *path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int columns,
    int rows,
    int *master_fd,
    pid_t *child_pid) {
  int master = posix_openpt(O_RDWR | O_NOCTTY);
  if (master == -1) return errno;
  if (grantpt(master) == -1 || unlockpt(master) == -1) {
    int error = errno;
    close(master);
    return error;
  }

  char *slave_name = ptsname(master);
  if (slave_name == NULL) {
    int error = errno;
    close(master);
    return error;
  }

  int slave = open(slave_name, O_RDWR | O_NOCTTY);
  if (slave == -1) {
    int error = errno;
    close(master);
    return error;
  }
  struct winsize size = scribe_winsize(columns, rows);
  if (ioctl(slave, TIOCSWINSZ, &size) == -1) {
    int error = errno;
    close(slave);
    close(master);
    return error;
  }

  pid_t pid = fork();
  if (pid == -1) {
    int error = errno;
    close(slave);
    close(master);
    return error;
  }
  if (pid == 0) {
    close(master);
    if (setsid() == -1 || ioctl(slave, TIOCSCTTY, 0) == -1) _exit(127);
    if (dup2(slave, STDIN_FILENO) == -1 ||
        dup2(slave, STDOUT_FILENO) == -1 ||
        dup2(slave, STDERR_FILENO) == -1) _exit(127);
    if (slave > STDERR_FILENO) close(slave);
    if (working_directory != NULL && chdir(working_directory) == -1) _exit(127);

    // Signals ignored by GUI applications must have normal shell defaults.
    signal(SIGINT, SIG_DFL);
    signal(SIGQUIT, SIG_DFL);
    signal(SIGTSTP, SIG_DFL);
    signal(SIGTTIN, SIG_DFL);
    signal(SIGTTOU, SIG_DFL);
    signal(SIGCHLD, SIG_DFL);

    execve(path, argv, envp);
    _exit(127);
  }

  close(slave);
  int flags = fcntl(master, F_GETFD);
  if (flags != -1) fcntl(master, F_SETFD, flags | FD_CLOEXEC);
  *master_fd = master;
  *child_pid = pid;
  return 0;
}
