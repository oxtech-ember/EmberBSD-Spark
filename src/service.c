#define _POSIX_C_SOURCE 200809L
#define _NETBSD_SOURCE
#define _DARWIN_C_SOURCE
#include "host.h"
#include <sys/stat.h>
#include <syslog.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Service ownership belongs to this process. No resident wrapper or restart
 * loop is needed; rc.d controls the foreground agent directly. */
static volatile sig_atomic_t pid_fd = -1;
static char pid_path[PATH_MAX];
static int use_syslog;

void host_service_release(void) {
    int fd = pid_fd;
    if (fd < 0) return;
    pid_fd = -1;
    struct stat held, named;
    /* A replacement file belongs to its new owner, including after SIGKILL. */
    if (!fstat(fd, &held) && !lstat(pid_path, &named) &&
        held.st_dev == named.st_dev && held.st_ino == named.st_ino)
        unlink(pid_path);
    close(fd);
}

static void service_close(void) {
    host_service_release();
    if (use_syslog) closelog();
}

void host_log(int error, const char *message) {
    if (use_syslog) syslog(error ? LOG_ERR : LOG_INFO, "%s", message);
    else fprintf(stderr, "%s\n", message);
}

int host_service_open(void) {
    const char *logging = getenv("OXTORG_AGENT_SYSLOG");
    use_syslog = logging && !strcmp(logging, "1");
    if (use_syslog) openlog("oxtorg_agent", LOG_PID | LOG_NDELAY, LOG_DAEMON);
    if (atexit(service_close)) { errno = ENOMEM; return -1; }
    const char *path = getenv("OXTORG_AGENT_PIDFILE");
    if (!path || !*path) return 0;
    if (strlen(path) >= sizeof pid_path) { errno = ENAMETOOLONG; return -1; }
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
    if (fd < 0) return -1;
    struct stat info;
    if (fstat(fd, &info)) { int error = errno; close(fd); errno = error; return -1; }
    if (!S_ISREG(info.st_mode)) { close(fd); errno = EINVAL; return -1; }
    struct flock lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
    if (fcntl(fd, F_SETLK, &lock)) {
        int error = errno; close(fd); errno = error; return -1;
    }
    strcpy(pid_path, path);
    pid_fd = fd;
    if (ftruncate(fd, 0) || dprintf(fd, "%ld\n", (long)getpid()) < 0) {
        int error = errno; host_service_release(); errno = error; return -1;
    }
    return 0;
}
