#define _POSIX_C_SOURCE 200809L
#define _NETBSD_SOURCE
#define _DARWIN_C_SOURCE
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>
#ifdef __NetBSD__
#include <bluetooth.h>
#endif

#if defined(__NetBSD__) || defined(BLUETOOTH_ADMIN_TEST)
/* Only controller administration crosses this privilege boundary. Sessions,
 * JSON tool arguments and the Lua VM stay in the unprivileged agent. */
static const char *pin_path = "/etc/oxtorg/bluetooth-pins.json";
static volatile sig_atomic_t stopping;
static char *environment[] = {"PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/pkg/bin", "LC_ALL=C", NULL};
#ifdef BLUETOOTH_ADMIN_TEST
static const char *test_dir;
static int test_timeout;
#endif
static void interrupted(int number) { (void)number; stopping = 1; }
static int64_t now_ms(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
static void wipe(void *data, size_t size) {
    volatile unsigned char *p = data;
    while (size--) *p++ = 0;
}
static int address_valid(const char *address) {
    if (strlen(address) != 17) return 0;
    for (int i = 0; i < 17; ++i)
        if (i % 3 == 2 ? address[i] != ':' : !isxdigit((unsigned char)address[i])) return 0;
    return 1;
}
/* The caller keeps stdin open for the duration of an operation. EOF cancels
 * privileged descendants even when the caller cannot signal their new UID. */
static int wait_ready(int fd, short events, int64_t until) {
    for (;;) {
        if (stopping) { errno = ECANCELED; return -1; }
        int64_t left = until - now_ms();
        if (left <= 0) { errno = ETIMEDOUT; return -1; }
        struct pollfd ready[] = {{STDIN_FILENO, POLLIN, 0}, {fd, events, 0}};
        int count = poll(ready, 2, left < 100 ? (int)left : 100);
        if (count < 0) { if (errno == EINTR) continue; return -1; }
        if (ready[0].revents) {
            char discard[64];
            ssize_t bytes = read(STDIN_FILENO, discard, sizeof discard);
            if (bytes <= 0) { errno = ECANCELED; return -1; }
        }
        if (fd < 0 || ready[1].revents) return 0;
    }
}
static int hex(int ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}
static int unicode_unit(FILE *file) {
    int value = 0;
    for (int i = 0; i < 4; ++i) {
        if (ferror(file) || feof(file)) return -1;
        int ch = fgetc(file);
        if (ch == EOF) return -1;
        int digit = hex(ch);
        if (digit < 0) return -1;
        value = value * 16 + digit;
    }
    return value;
}
static int nonspace(FILE *file) {
    int ch;
    do { ch = fgetc(file); } while (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n');
    return ch;
}
/* Stream the fixed string-map format; never materialize the PIN database. */
static int json_string(FILE *file, char *output, size_t capacity) {
    size_t length = 0;
    if (nonspace(file) != '"') return -1;
    for (;;) {
        int ch = fgetc(file);
        if (ch == '"') { output[length] = 0; return (int)length; }
        if (ch < 0x20) return -1;
        unsigned char bytes[4]; size_t count = 1;
        bytes[0] = (unsigned char)ch;
        if (ch == '\\') {
            ch = fgetc(file);
            switch (ch) {
            case '"': case '\\': case '/': bytes[0] = (unsigned char)ch; break;
            case 'b': bytes[0] = '\b'; break;
            case 'f': bytes[0] = '\f'; break;
            case 'n': bytes[0] = '\n'; break;
            case 'r': bytes[0] = '\r'; break;
            case 't': bytes[0] = '\t'; break;
            case 'u': {
                int code = unicode_unit(file);
                if (code <= 0 || (code >= 0xdc00 && code <= 0xdfff)) return -1;
                if (code >= 0xd800 && code <= 0xdbff) {
                    if (fgetc(file) != '\\' || fgetc(file) != 'u') return -1;
                    int low = unicode_unit(file);
                    if (low < 0xdc00 || low > 0xdfff) return -1;
                    code = 0x10000 + (code - 0xd800) * 1024 + low - 0xdc00;
                }
                if (code < 0x80) bytes[0] = (unsigned char)code;
                else if (code < 0x800) {
                    count = 2; bytes[0] = 0xc0 | (code >> 6); bytes[1] = 0x80 | (code & 63);
                } else if (code < 0x10000) {
                    count = 3; bytes[0] = 0xe0 | (code >> 12); bytes[1] = 0x80 | ((code >> 6) & 63); bytes[2] = 0x80 | (code & 63);
                } else {
                    count = 4; bytes[0] = 0xf0 | (code >> 18); bytes[1] = 0x80 | ((code >> 12) & 63);
                    bytes[2] = 0x80 | ((code >> 6) & 63); bytes[3] = 0x80 | (code & 63);
                }
                break;
            }
            default: return -1;
            }
        }
        if (length + count >= capacity) return -1;
        memcpy(output + length, bytes, count); length += count;
    }
}
static int private_pin(const char *address, char result[17]) {
    int fd = open(pin_path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return -1;
    struct stat info;
    uid_t owner = 0;
#ifdef BLUETOOTH_ADMIN_TEST
    owner = geteuid();
#endif
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != owner ||
        (info.st_mode & 0777) != 0600 || info.st_size < 2 || info.st_size > 65536) {
        close(fd); errno = EACCES; return -1;
    }
    FILE *file = fdopen(fd, "r");
    if (!file) { close(fd); return -1; }
    int found = 0, valid = 0;
    char key[18], value[17];
    if (nonspace(file) != '{') goto done;
    int next = nonspace(file);
    if (next == '}') goto end;
    if (next == EOF || ungetc(next, file) == EOF) goto done;
    for (;;) {
        if (json_string(file, key, sizeof key) < 0 || !address_valid(key) || nonspace(file) != ':' ||
            json_string(file, value, sizeof value) <= 0) goto done;
        if (!strcasecmp(key, address)) {
            if (found) goto done;
            strcpy(result, value); found = 1;
        }
        wipe(value, sizeof value);
        next = nonspace(file);
        if (next == '}') break;
        if (next != ',') goto done;
    }
end:
    valid = nonspace(file) == EOF && !ferror(file) && found;
done:
    wipe(value, sizeof value);
    fclose(file);
    if (!valid) { wipe(result, 17); errno = EINVAL; return -1; }
    return 0;
}
static int register_pin(const char *address) {
    char pin[17] = {0};
    if (private_pin(address, pin)) return -1;
    int result = -1;
#ifdef BLUETOOTH_ADMIN_TEST
    char path[PATH_MAX];
    if (test_dir && snprintf(path, sizeof path, "%s/pin.received", test_dir) < (int)sizeof path) {
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd >= 0) { result = write(fd, pin, strlen(pin)) == (ssize_t)strlen(pin) ? 0 : -1; close(fd); }
    }
#elif defined(__NetBSD__)
    bthcid_pin_response_t response;
    memset(&response, 0, sizeof response);
    if (bt_aton(address, &response.raddr) && bt_devaddr("btuart0", &response.laddr)) {
        memcpy(response.pin, pin, strlen(pin));
        int fd = socket(AF_LOCAL, SOCK_STREAM, 0);
        if (fd >= 0) {
            struct sockaddr_un destination;
            memset(&destination, 0, sizeof destination);
            destination.sun_len = sizeof destination;
            destination.sun_family = AF_LOCAL;
            strcpy(destination.sun_path, BTHCID_SOCKET_NAME);
            int flags = fcntl(fd, F_GETFL);
            int64_t until = now_ms() + 3000;
            if (flags >= 0 && !fcntl(fd, F_SETFD, FD_CLOEXEC) && !fcntl(fd, F_SETFL, flags | O_NONBLOCK)) {
                int connected = connect(fd, (struct sockaddr *)&destination, sizeof destination);
                if (connected < 0 && errno == EINPROGRESS && !wait_ready(fd, POLLOUT, until)) {
                    int error = 0; socklen_t length = sizeof error;
                    connected = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length);
                    if (error) { errno = error; connected = -1; }
                }
                if (!connected) {
                    size_t sent = 0;
                    while (sent < sizeof response && !wait_ready(fd, POLLOUT, until)) {
                        ssize_t n = send(fd, (char *)&response + sent, sizeof response - sent, 0);
                        if (n > 0) sent += (size_t)n;
                        else if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
                        else break;
                    }
                    if (sent == sizeof response) result = 0;
                }
            }
            int error = errno; close(fd); errno = error;
        }
    }
    wipe(&response, sizeof response);
#endif
    wipe(pin, sizeof pin);
    return result;
}
static int command(char **argv, int timeout) {
    char *run[6];
    memcpy(run, argv, sizeof run);
#ifdef BLUETOOTH_ADMIN_TEST
    char program[PATH_MAX];
    if (test_dir) {
        const char *base = strrchr(argv[0], '/');
        if (snprintf(program, sizeof program, "%s/%s", test_dir, base ? base + 1 : argv[0]) >= (int)sizeof program) return -1;
        run[0] = program;
    }
    if (test_timeout) timeout = test_timeout;
#endif
    pid_t child = fork();
    if (child < 0) return -1;
    if (!child) {
        if (setpgid(0, 0)) _exit(126);
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGPIPE, SIG_DFL);
        int input = open("/dev/null", O_RDONLY);
        if (input < 0 || dup2(input, STDIN_FILENO) < 0) _exit(126);
#ifdef __NetBSD__
        closefrom(3);
#else
        long limit = sysconf(_SC_OPEN_MAX);
        for (int fd = 3; fd < limit; ++fd) close(fd);
#endif
        execve(run[0], run, environment);
        _exit(127);
    }
    (void)setpgid(child, child);
    int64_t until = now_ms() + timeout;
    int completed = 0;
    for (;;) {
        siginfo_t info;
        memset(&info, 0, sizeof info);
        if (!waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT)) {
            if (info.si_pid) { completed = 1; break; }
        } else if (errno != EINTR) break;
        if (wait_ready(-1, 0, until)) break;
    }
    int error = errno, status;
    /* Keep the leader unreaped until its descendants have been terminated. */
    kill(-child, SIGKILL);
    pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    if (!completed || waited < 0) { errno = error; return -1; }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
int main(int argc, char **argv) {
    extern char **environ;
    environ = environment;
#ifdef BLUETOOTH_ADMIN_TEST
    while (argc > 2 && argv[1][0] == '-') {
        if (!strcmp(argv[1], "--test-dir")) test_dir = argv[2];
        else if (!strcmp(argv[1], "--pin-file")) pin_path = argv[2];
        else if (!strcmp(argv[1], "--timeout-ms")) {
            char *end; long ms = strtol(argv[2], &end, 10);
            if (*end || ms < 1 || ms > 100000) return 2;
            test_timeout = (int)ms;
        } else return 2;
        argc -= 2; argv += 2;
    }
#else
    uid_t caller = getuid();
    struct passwd *account = getpwnam("oxtorg");
    if (geteuid() || (caller && (!account || caller != account->pw_uid))) {
        fputs("Bluetooth administration requires the installed oxtorg helper.\n", stderr); return 1;
    }
    /* A privileged child must be cancelled by EOF, not killed before it can
     * reap root descendants. Give this short-lived supervisor root IDs too. */
    if (setgid(0) || setuid(0)) { perror("Bluetooth privilege setup"); return 1; }
#endif
    struct rlimit core = {0, 0};
    if (setrlimit(RLIMIT_CORE, &core)) return 1;
    umask(0077);
    struct sigaction action;
    memset(&action, 0, sizeof action); sigemptyset(&action.sa_mask);
    action.sa_handler = interrupted; sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL);
    action.sa_handler = SIG_IGN; sigaction(SIGPIPE, &action, NULL);
    char *args[6] = {0}; int timeout;
    if (argc == 2 && !strcmp(argv[1], "state")) {
        args[0] = "/opt/oxtorg/bin/bluetooth-control"; args[1] = "btuart0"; args[2] = "state"; timeout = 8000;
    } else if (argc == 3 && !strcmp(argv[1], "power") && !strcmp(argv[2], "on")) {
        args[0] = "/etc/rc.d/oxtorg_bluetooth"; args[1] = "onestart"; timeout = 20000;
    } else if (argc == 3 && !strcmp(argv[1], "power") && !strcmp(argv[2], "off")) {
        args[0] = "/usr/sbin/btconfig"; args[1] = "btuart0"; args[2] = "disable"; timeout = 20000;
    } else if (argc == 4 && !strcmp(argv[1], "pair") && address_valid(argv[2]) &&
        (!strcmp(argv[3], "bonded") || !strcmp(argv[3], "just-works") || !strcmp(argv[3], "legacy-pin"))) {
        if (!strcmp(argv[3], "legacy-pin") && register_pin(argv[2])) {
            fputs("Cannot register the selected device's private PIN.\n", stderr); return 1;
        }
        args[0] = "/opt/oxtorg/bin/bluetooth-pair";
        args[1] = !strcmp(argv[3], "bonded") ? "-b" : !strcmp(argv[3], "just-works") ? "-j" : "-l";
        args[2] = "btuart0"; args[3] = argv[2]; timeout = 100000;
    } else {
        fputs("Usage: bluetooth-admin state | power on|off | pair ADDRESS bonded|just-works|legacy-pin\n", stderr); return 2;
    }
    int result = command(args, timeout);
    if (result < 0) { perror("Bluetooth administration"); return 1; }
    return result;
}
#else
int main(void) { fputs("Bluetooth administration requires NetBSD.\n", stderr); return 1; }
#endif
