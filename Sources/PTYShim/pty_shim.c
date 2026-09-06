#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include "pty_shim.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <pthread.h>
#if defined(__APPLE__)
#include <libproc.h>
#elif defined(__linux__)
#include <dirent.h>
#endif
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

// fork() duplicates descriptors from every concurrently spawning terminal.
// Serialize the small fork/handshake window so private control and readiness
// pipes cannot leak into sibling supervisors.
static pthread_mutex_t scribe_spawn_lock = PTHREAD_MUTEX_INITIALIZER;

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

int scribe_set_nonblocking(int fd, int enabled) {
  int flags;
  do {
    flags = fcntl(fd, F_GETFL);
  } while (flags == -1 && errno == EINTR);
  if (flags == -1) return errno;

  int result;
  do {
    result = fcntl(fd, F_SETFL, enabled ? flags | O_NONBLOCK : flags & ~O_NONBLOCK);
  } while (result == -1 && errno == EINTR);
  return result == -1 ? errno : 0;
}

static void scribe_kill_session(pid_t leader) {
  if (leader <= 2) return;

  // A terminal's background jobs have their own process groups but retain the
  // shell's session ID. Signal every member so jobs cannot survive shutdown.
#if defined(__APPLE__)
  int bytes = proc_listallpids(NULL, 0);
  if (bytes > 0) {
    size_t capacity = (size_t)bytes / sizeof(pid_t) + 32;
    pid_t *pids = calloc(capacity, sizeof(pid_t));
    if (pids != NULL) {
      int count = proc_listallpids(pids, (int)(capacity * sizeof(pid_t)));
      for (int i = 0; i < count; i++) {
        if (pids[i] > 2 && getsid(pids[i]) == leader) (void)kill(pids[i], SIGKILL);
      }
      free(pids);
    }
  }
#elif defined(__linux__)
  DIR *directory = opendir("/proc");
  if (directory != NULL) {
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
      char *end = NULL;
      long value = strtol(entry->d_name, &end, 10);
      if (end != entry->d_name && *end == '\0' && value > 2) {
        pid_t pid = (pid_t)value;
        if (getsid(pid) == leader) (void)kill(pid, SIGKILL);
      }
    }
    closedir(directory);
  }
#endif
  // Always include the original group as a fallback and to close enumeration races.
  (void)kill(-leader, SIGKILL);
}

// Runs in the supervisor process. The supervisor is intentionally tiny: it
// owns no application state or threads, and only waits for the terminal leader,
// an explicit close byte, or reparenting caused by daemon death.
static void scribe_supervise(pid_t leader, int control_read, pid_t owner) {
  for (;;) {
    int status = 0;
    if (getppid() != owner) {
      scribe_kill_session(leader);
      do {
        errno = 0;
      } while (waitpid(leader, &status, 0) == -1 && errno == EINTR);
      _exit(128 + SIGKILL);
    }
    pid_t waited = waitpid(leader, &status, WNOHANG);
    if (waited == leader) {
      // The shell may leave background jobs in its group after exiting.
      scribe_kill_session(leader);
      _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
    }
    if (waited == -1 && errno != EINTR) {
      scribe_kill_session(leader);
      _exit(127);
    }

    fd_set read_fds;
    FD_ZERO(&read_fds);
    FD_SET(control_read, &read_fds);
    struct timeval timeout = {.tv_sec = 0, .tv_usec = 100000};
    int selected = select(control_read + 1, &read_fds, NULL, NULL, &timeout);
    if (selected > 0 && FD_ISSET(control_read, &read_fds)) {
      char byte;
      ssize_t count;
      do {
        count = read(control_read, &byte, 1);
      } while (count == -1 && errno == EINTR);
      if (count == 1 || (count == -1 && errno != EAGAIN)) {
        scribe_kill_session(leader);
        do {
          waited = waitpid(leader, &status, 0);
        } while (waited == -1 && errno == EINTR);
        _exit(waited == leader && WIFEXITED(status) ? WEXITSTATUS(status) : 128 + SIGKILL);
      }
    } else if (selected == -1 && errno != EINTR) {
      scribe_kill_session(leader);
      _exit(127);
    }
  }
}

static int scribe_pty_spawn_locked(
    const char *path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int columns,
    int rows,
    int *master_fd,
    pid_t *supervisor_pid,
    pid_t *process_group_pid,
    int *control_fd) {
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

  int control[2] = {-1, -1};
  int ready[2] = {-1, -1};
  if (pipe(control) == -1) {
    int error = errno;
    close(slave);
    close(master);
    return error;
  }
  if (pipe(ready) == -1) {
    int error = errno;
    close(control[0]);
    close(control[1]);
    close(slave);
    close(master);
    return error;
  }
  (void)fcntl(control[0], F_SETFD, FD_CLOEXEC);
  (void)fcntl(control[1], F_SETFD, FD_CLOEXEC);
  (void)fcntl(ready[0], F_SETFD, FD_CLOEXEC);
  (void)fcntl(ready[1], F_SETFD, FD_CLOEXEC);

  pid_t owner = getpid();
  pid_t supervisor = fork();
  if (supervisor == -1) {
    int error = errno;
    close(control[0]);
    close(control[1]);
    close(ready[0]);
    close(ready[1]);
    close(slave);
    close(master);
    return error;
  }
  if (supervisor == 0) {
    close(control[1]);
    close(ready[0]);
    pid_t leader = fork();
    if (leader == -1) {
      pid_t failure = -1;
      (void)write(ready[1], &failure, sizeof(failure));
      _exit(127);
    }
    if (leader == 0) {
      close(control[0]);
      close(ready[1]);
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
      signal(SIGHUP, SIG_DFL);
      signal(SIGTERM, SIG_DFL);

      execve(path, argv, envp);
      _exit(127);
    }

    close(slave);
    ssize_t written;
    do {
      written = write(ready[1], &leader, sizeof(leader));
    } while (written == -1 && errno == EINTR);
    close(ready[1]);
    if (written != sizeof(leader)) {
      scribe_kill_session(leader);
      _exit(127);
    }
    scribe_supervise(leader, control[0], owner);
  }

  close(control[0]);
  close(ready[1]);
  close(slave);
  pid_t leader = -1;
  size_t received = 0;
  while (received < sizeof(leader)) {
    ssize_t count = read(ready[0], ((char *)&leader) + received, sizeof(leader) - received);
    if (count > 0) {
      received += (size_t)count;
    } else if (count == -1 && errno == EINTR) {
      continue;
    } else {
      break;
    }
  }
  close(ready[0]);
  if (received != sizeof(leader) || leader <= 2) {
    int error = ECHILD;
    close(control[1]);
    close(master);
    int status;
    while (waitpid(supervisor, &status, 0) == -1 && errno == EINTR) {}
    return error;
  }

  int flags = fcntl(master, F_GETFD);
  if (flags != -1) fcntl(master, F_SETFD, flags | FD_CLOEXEC);
  *master_fd = master;
  *supervisor_pid = supervisor;
  *process_group_pid = leader;
  *control_fd = control[1];
  return 0;
}

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
    int *control_fd) {
  int lock_result = pthread_mutex_lock(&scribe_spawn_lock);
  if (lock_result != 0) return lock_result;
  int result = scribe_pty_spawn_locked(
      path, argv, envp, working_directory, columns, rows, master_fd,
      supervisor_pid, process_group_pid, control_fd);
  int unlock_result = pthread_mutex_unlock(&scribe_spawn_lock);
  return result != 0 ? result : unlock_result;
}
