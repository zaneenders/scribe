#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include "pty_shim.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#if defined(__APPLE__)
#include <libproc.h>
#elif defined(__linux__)
#include <dirent.h>
#include <sys/syscall.h>
#endif
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

// fork() duplicates descriptors from every concurrently spawning terminal.
// Serialize the fork/handshake window so private pipes cannot leak into sibling
// supervisors or terminal leaders.
static pthread_mutex_t scribe_spawn_lock = PTHREAD_MUTEX_INITIALIZER;

struct scribe_spawn_response {
  pid_t leader;
  int error;
};

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

static void scribe_set_cloexec(int fd) {
  int flags = fcntl(fd, F_GETFD);
  if (flags != -1) (void)fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static ssize_t scribe_write_all(int fd, const void *buffer, size_t length) {
  size_t written = 0;
  while (written < length) {
    ssize_t count = write(fd, (const char *)buffer + written, length - written);
    if (count > 0) {
      written += (size_t)count;
    } else if (count == -1 && errno == EINTR) {
      continue;
    } else {
      return -1;
    }
  }
  return (ssize_t)written;
}

static ssize_t scribe_read_all(int fd, void *buffer, size_t length) {
  size_t received = 0;
  while (received < length) {
    ssize_t count = read(fd, (char *)buffer + received, length - received);
    if (count > 0) {
      received += (size_t)count;
    } else if (count == -1 && errno == EINTR) {
      continue;
    } else {
      break;
    }
  }
  return (ssize_t)received;
}

// This is called only in a post-fork child. Actually close descriptors rather
// than merely setting CLOEXEC because the supervisor intentionally never execs.
static void scribe_close_unrelated_fds(long descriptor_limit, const int *keep, size_t keep_count) {
#if defined(__linux__) && defined(SYS_close_range)
  // Close ranges around the small allowlist without allocating or traversing
  // /proc in the post-fork child.
  int ordered[8];
  if (keep_count <= sizeof(ordered) / sizeof(ordered[0])) {
    for (size_t index = 0; index < keep_count; index++) ordered[index] = keep[index];
    for (size_t index = 1; index < keep_count; index++) {
      int value = ordered[index];
      size_t insertion = index;
      while (insertion > 0 && ordered[insertion - 1] > value) {
        ordered[insertion] = ordered[insertion - 1];
        insertion--;
      }
      ordered[insertion] = value;
    }
    unsigned int first = STDERR_FILENO + 1;
    int close_range_succeeded = 1;
    for (size_t index = 0; index < keep_count; index++) {
      if (ordered[index] < (int)first) continue;
      if ((unsigned int)ordered[index] > first &&
          syscall(SYS_close_range, first, (unsigned int)ordered[index] - 1, 0) == -1) {
        close_range_succeeded = 0;
      }
      first = (unsigned int)ordered[index] + 1;
    }
    if (syscall(SYS_close_range, first, ~0U, 0) == -1) close_range_succeeded = 0;
    if (close_range_succeeded) return;
  }
#endif
  for (int fd = STDERR_FILENO + 1; fd < descriptor_limit; fd++) {
    int should_keep = 0;
    for (size_t index = 0; index < keep_count; index++) {
      if (keep[index] == fd) {
        should_keep = 1;
        break;
      }
    }
    if (!should_keep) (void)close(fd);
  }
}

static void scribe_kill_session(pid_t leader) {
  if (leader <= 2) return;

  // A terminal's background jobs have their own process groups but retain the
  // shell's session ID. Signal every member so jobs cannot survive shutdown.
#if defined(__APPLE__)
  int estimated_count = proc_listallpids(NULL, 0);
  if (estimated_count > 0) {
    size_t capacity = (size_t)estimated_count + 32;
    for (int attempt = 0; attempt < 3; attempt++) {
      pid_t *pids = calloc(capacity, sizeof(pid_t));
      if (pids == NULL) break;
      int count = proc_listallpids(pids, (int)(capacity * sizeof(pid_t)));
      if (count < 0) count = 0;
      for (int i = 0; i < count; i++) {
        if (pids[i] > 2 && getsid(pids[i]) == leader) (void)kill(pids[i], SIGKILL);
      }
      free(pids);
      if ((size_t)count < capacity) break;
      capacity *= 2;
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

static void scribe_report_status_and_exit(int status_fd, int status) {
  (void)scribe_write_all(status_fd, &status, sizeof(status));
  close(status_fd);
  _exit(0);
}

// Runs in the supervisor process and owns/reaps the terminal leader. EOF on the
// control pipe is the close request, which avoids any SIGPIPE-producing write in
// the owner. The leader's unmodified wait status is reported on status_write.
static void scribe_supervise(pid_t leader, int control_read, int status_write, pid_t owner) {
  for (;;) {
    int status = 0;
    if (getppid() != owner) {
      scribe_kill_session(leader);
      while (waitpid(leader, &status, 0) == -1 && errno == EINTR) {}
      scribe_report_status_and_exit(status_write, status);
    }

    pid_t waited = waitpid(leader, &status, WNOHANG);
    if (waited == leader) {
      // The shell may leave background jobs in its group after exiting.
      scribe_kill_session(leader);
      scribe_report_status_and_exit(status_write, status);
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
      if (count == 0 || count == 1 || (count == -1 && errno != EAGAIN)) {
        scribe_kill_session(leader);
        do {
          waited = waitpid(leader, &status, 0);
        } while (waited == -1 && errno == EINTR);
        if (waited == leader) scribe_report_status_and_exit(status_write, status);
        _exit(127);
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
    int *control_fd,
    int *status_fd) {
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
  int setup[2] = {-1, -1};
  int status[2] = {-1, -1};
  if (pipe(control) == -1 || pipe(ready) == -1 || pipe(setup) == -1 || pipe(status) == -1) {
    int error = errno;
    if (control[0] >= 0) close(control[0]);
    if (control[1] >= 0) close(control[1]);
    if (ready[0] >= 0) close(ready[0]);
    if (ready[1] >= 0) close(ready[1]);
    if (setup[0] >= 0) close(setup[0]);
    if (setup[1] >= 0) close(setup[1]);
    if (status[0] >= 0) close(status[0]);
    if (status[1] >= 0) close(status[1]);
    close(slave);
    close(master);
    return error;
  }
  scribe_set_cloexec(control[0]);
  scribe_set_cloexec(control[1]);
  scribe_set_cloexec(ready[0]);
  scribe_set_cloexec(ready[1]);
  scribe_set_cloexec(setup[0]);
  scribe_set_cloexec(setup[1]);
  scribe_set_cloexec(status[0]);
  scribe_set_cloexec(status[1]);

  long descriptor_limit = sysconf(_SC_OPEN_MAX);
  if (descriptor_limit < 0) descriptor_limit = 1024;
  pid_t owner = getpid();
  pid_t supervisor = fork();
  if (supervisor == -1) {
    int error = errno;
    close(control[0]); close(control[1]);
    close(ready[0]); close(ready[1]);
    close(setup[0]); close(setup[1]);
    close(status[0]); close(status[1]);
    close(slave);
    close(master);
    return error;
  }

  if (supervisor == 0) {
    close(control[1]);
    close(ready[0]);
    close(setup[1]);
    close(status[0]);

    pid_t leader = fork();
    if (leader == -1) {
      struct scribe_spawn_response response = {.leader = -1, .error = errno};
      (void)scribe_write_all(ready[1], &response, sizeof(response));
      _exit(127);
    }
    if (leader == 0) {
      close(control[0]);
      close(ready[1]);
      close(setup[0]);
      close(status[1]);
      close(master);

#define SCRIBE_SETUP_OR_EXIT(expression) do { \
  if ((expression) == -1) { \
    int setup_error = errno; \
    (void)scribe_write_all(setup[1], &setup_error, sizeof(setup_error)); \
    _exit(127); \
  } \
} while (0)

      SCRIBE_SETUP_OR_EXIT(setsid());
      SCRIBE_SETUP_OR_EXIT(ioctl(slave, TIOCSCTTY, 0));
      SCRIBE_SETUP_OR_EXIT(dup2(slave, STDIN_FILENO));
      SCRIBE_SETUP_OR_EXIT(dup2(slave, STDOUT_FILENO));
      SCRIBE_SETUP_OR_EXIT(dup2(slave, STDERR_FILENO));
      if (slave > STDERR_FILENO) close(slave);
      if (working_directory != NULL) SCRIBE_SETUP_OR_EXIT(chdir(working_directory));

      // Signals ignored by GUI applications must have normal shell defaults.
      signal(SIGINT, SIG_DFL);
      signal(SIGQUIT, SIG_DFL);
      signal(SIGTSTP, SIG_DFL);
      signal(SIGTTIN, SIG_DFL);
      signal(SIGTTOU, SIG_DFL);
      signal(SIGCHLD, SIG_DFL);
      signal(SIGHUP, SIG_DFL);
      signal(SIGTERM, SIG_DFL);

      int leader_keep[] = {setup[1]};
      scribe_close_unrelated_fds(descriptor_limit, leader_keep, 1);
      execve(path, argv, envp);
      int setup_error = errno;
      (void)scribe_write_all(setup[1], &setup_error, sizeof(setup_error));
      _exit(127);
    }

    close(slave);
    close(master);
    int supervisor_keep[] = {control[0], ready[1], setup[0], status[1]};
    scribe_close_unrelated_fds(descriptor_limit, supervisor_keep, 4);

    int setup_error = 0;
    ssize_t setup_count = scribe_read_all(setup[0], &setup_error, sizeof(setup_error));
    close(setup[0]);
    if (setup_count != 0) {
      int child_status;
      while (waitpid(leader, &child_status, 0) == -1 && errno == EINTR) {}
      struct scribe_spawn_response response = {
        .leader = -1,
        .error = setup_count == sizeof(setup_error) ? setup_error : EIO,
      };
      (void)scribe_write_all(ready[1], &response, sizeof(response));
      close(ready[1]);
      _exit(127);
    }

    struct scribe_spawn_response response = {.leader = leader, .error = 0};
    if (scribe_write_all(ready[1], &response, sizeof(response)) != sizeof(response)) {
      scribe_kill_session(leader);
      while (waitpid(leader, NULL, 0) == -1 && errno == EINTR) {}
      _exit(127);
    }
    close(ready[1]);
    scribe_supervise(leader, control[0], status[1], owner);
  }

  close(control[0]);
  close(ready[1]);
  close(setup[0]);
  close(setup[1]);
  close(status[1]);
  close(slave);

  struct scribe_spawn_response response = {.leader = -1, .error = ECHILD};
  ssize_t received = scribe_read_all(ready[0], &response, sizeof(response));
  close(ready[0]);
  if (received != sizeof(response) || response.error != 0 || response.leader <= 2) {
    int error = received == sizeof(response) && response.error != 0 ? response.error : ECHILD;
    close(control[1]);
    close(status[0]);
    close(master);
    int supervisor_status;
    while (waitpid(supervisor, &supervisor_status, 0) == -1 && errno == EINTR) {}
    return error;
  }

  scribe_set_cloexec(master);
  *master_fd = master;
  *supervisor_pid = supervisor;
  *process_group_pid = response.leader;
  *control_fd = control[1];
  *status_fd = status[0];
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
    int *control_fd,
    int *status_fd) {
  int lock_result = pthread_mutex_lock(&scribe_spawn_lock);
  if (lock_result != 0) return lock_result;
  int result = scribe_pty_spawn_locked(
      path, argv, envp, working_directory, columns, rows, master_fd,
      supervisor_pid, process_group_pid, control_fd, status_fd);
  int unlock_result = pthread_mutex_unlock(&scribe_spawn_lock);
  return result != 0 ? result : unlock_result;
}
