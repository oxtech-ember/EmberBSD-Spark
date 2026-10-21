#define _GNU_SOURCE
#define _NETBSD_SOURCE
#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "host.h"
#include <lauxlib.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#define PROCESS_META "asenta.process.child"
#define DEFAULT_STDOUT_BYTES (1024U * 1024U)
#define DEFAULT_STDERR_BYTES (64U * 1024U)

struct process {
    int in, out, err, exited, code;
    volatile sig_atomic_t group;
    char *output, *errors;
    size_t output_size, output_capacity, output_limit;
    size_t error_size, error_limit;
    struct process *next;
};

static struct process *children;

static int64_t milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) return 0;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void block_signals(sigset_t *previous) {
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGINT);
    sigaddset(&set, SIGTERM);
    sigprocmask(SIG_BLOCK, &set, previous);
}

static void close_fd(int *fd) {
    if (*fd >= 0) close(*fd);
    *fd = -1;
}

/* Signal handlers only visit this list while its links are stable. */
void host_process_signal(int sig) {
    int saved = errno;
    for (struct process *p = children; p; p = p->next)
        if (p->group > 0) kill(-(pid_t)p->group, sig);
    errno = saved;
}

static void unlink_child(struct process *p) {
    sigset_t previous;
    block_signals(&previous);
    struct process **link = &children;
    while (*link && *link != p) link = &(*link)->next;
    if (*link) *link = p->next;
    p->next = NULL;
    sigprocmask(SIG_SETMASK, &previous, NULL);
}

/* Keep the leader's PID reserved until its descendants have been stopped. */
static int reap(struct process *p) {
    if (p->exited || p->group <= 0) return 0;
    sigset_t previous;
    block_signals(&previous);
    siginfo_t info;
    memset(&info, 0, sizeof info);
    pid_t pid = (pid_t)p->group;
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) < 0) {
        if (errno == EINTR) { sigprocmask(SIG_SETMASK, &previous, NULL); return 0; }
        if (errno != ECHILD) {
            int error = errno;
            sigprocmask(SIG_SETMASK, &previous, NULL);
            errno = error;
            return -1;
        }
        /* Another owner reaped it; never signal a possibly reused PID. */
        p->code = 255;
    } else {
        if (!info.si_pid) { sigprocmask(SIG_SETMASK, &previous, NULL); return 0; }
        kill(-pid, SIGKILL);
        int status;
        while (waitpid(pid, &status, 0) < 0) {
            if (errno == EINTR) continue;
            int error = errno;
            sigprocmask(SIG_SETMASK, &previous, NULL);
            errno = error;
            return -1;
        }
        p->code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    }
    p->group = 0;
    p->exited = 1;
    sigprocmask(SIG_SETMASK, &previous, NULL);
    close_fd(&p->in);
    return 0;
}

static void save_stderr(struct process *p, const char *bytes, size_t size) {
    if (!p->error_limit) return;
    if (size >= p->error_limit) {
        memcpy(p->errors, bytes + size - p->error_limit, p->error_limit);
        p->error_size = p->error_limit;
        return;
    }
    size_t discard = p->error_size + size > p->error_limit
        ? p->error_size + size - p->error_limit : 0;
    if (discard) {
        memmove(p->errors, p->errors + discard, p->error_size - discard);
        p->error_size -= discard;
    }
    memcpy(p->errors + p->error_size, bytes, size);
    p->error_size += size;
}

static int save_stdout(struct process *p, const char *bytes, size_t size) {
    if (size > p->output_limit - p->output_size) { errno = EOVERFLOW; return -1; }
    size_t need = p->output_size + size;
    if (need > p->output_capacity) {
        size_t capacity = p->output_capacity ? p->output_capacity : 4096;
        while (capacity < need && capacity <= p->output_limit / 2) capacity *= 2;
        if (capacity < need || capacity > p->output_limit) capacity = need;
        char *next = realloc(p->output, capacity);
        if (!next) { errno = ENOMEM; return -1; }
        p->output = next;
        p->output_capacity = capacity;
    }
    memcpy(p->output + p->output_size, bytes, size);
    p->output_size = need;
    return 0;
}

static int drain(struct process *p, int *fd, int is_stderr, int discard) {
    char bytes[16384];
    ssize_t size = read(*fd, bytes, sizeof bytes);
    if (size > 0) {
        if (is_stderr) save_stderr(p, bytes, (size_t)size);
        else if (!discard && save_stdout(p, bytes, (size_t)size) < 0) return -1;
    } else if (size == 0) {
        close_fd(fd);
    } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
        return -1;
    }
    return 0;
}

/* Read both output pipes while writing stdin: either can fill first. */
static int pump(struct process *p, int wait_ms, const char *bytes,
                size_t length, size_t *written, int discard) {
    struct pollfd fds[3] = {
        {p->out, POLLIN, 0}, {p->err, POLLIN, 0},
        {bytes && *written < length ? p->in : -1, POLLOUT, 0}
    };
    int ready = poll(fds, 3, wait_ms);
    if (ready < 0) return errno == EINTR ? 0 : -1;
    if (!ready) return 0;
    if (fds[1].revents && drain(p, &p->err, 1, discard) < 0) return -1;
    if (fds[0].revents && drain(p, &p->out, 0, discard) < 0) return -1;
    if (fds[2].revents) {
        size_t count = length - *written;
        if (count > 16384) count = 16384;
        ssize_t sent = write(p->in, bytes + *written, count);
        if (sent > 0) *written += (size_t)sent;
        else if (sent < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
            return -1;
    }
    return 0;
}

static void close_process(struct process *p) {
    if (p->group > 0) {
        kill(-(pid_t)p->group, SIGTERM);
        int64_t until = milliseconds() + 200;
        while (p->group > 0 && milliseconds() < until) {
            if (reap(p) < 0) break;
            if (p->group <= 0) break;
            size_t ignored = 0;
            if (pump(p, 10, NULL, 0, &ignored, 1) < 0) break;
        }
        if (p->group > 0) {
            sigset_t previous;
            block_signals(&previous);
            pid_t pid = (pid_t)p->group;
            kill(-pid, SIGKILL);
            int status = 0;
            pid_t result;
            do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
            p->code = result == pid
                ? (WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status)) : 255;
            p->group = 0;
            p->exited = 1;
            sigprocmask(SIG_SETMASK, &previous, NULL);
        }
    }
    /* Capture the final bounded diagnostic tail without waiting for a writer. */
    for (int i = 0; p->err >= 0 && i < 16; ++i) {
        struct pollfd fd = {p->err, POLLIN, 0};
        if (poll(&fd, 1, 0) <= 0 || drain(p, &p->err, 1, 1) < 0) break;
    }
    close_fd(&p->in);
    close_fd(&p->out);
    close_fd(&p->err);
    free(p->output);
    p->output = NULL;
    p->output_size = p->output_capacity = 0;
    unlink_child(p);
}

void host_process_close(void) {
    while (children) close_process(children);
}

static struct process *check_process(lua_State *L) {
    return luaL_checkudata(L, 1, PROCESS_META);
}

static int close_lua(lua_State *L) {
    close_process(check_process(L));
    return 0;
}

static int collect_lua(lua_State *L) {
    struct process *p = check_process(L);
    close_process(p);
    free(p->errors);
    p->errors = NULL;
    p->error_size = p->error_limit = 0;
    return 0;
}

static int pair(lua_State *L, const char *reason) {
    lua_pushnil(L);
    lua_pushstring(L, reason);
    return 2;
}

static int io_error(lua_State *L, struct process *p, int error) {
    close_process(p);
    if (error == EPIPE) return pair(L, "eof");
    return luaL_error(L, "process I/O: %s", error == EOVERFLOW
        ? "stdout exceeds stdoutBytes" : strerror(error));
}

static int64_t deadline(lua_State *L, int index) {
    lua_Integer timeout = luaL_optinteger(L, index, 30000);
    luaL_argcheck(L, timeout >= 0 && timeout <= INT_MAX, index,
                  "timeout must be milliseconds from 0 to INT_MAX");
    return milliseconds() + timeout;
}

static int remaining(int64_t until) {
    int64_t left = until - milliseconds();
    return left > 0 ? (left > INT_MAX ? INT_MAX : (int)left) : 0;
}

static int send_lua(lua_State *L) {
    struct process *p = check_process(L);
    size_t length;
    const char *bytes = luaL_checklstring(L, 2, &length);
    int64_t until = deadline(L, 3);
    if (p->in < 0) return pair(L, "eof");
    if (!length) { lua_pushboolean(L, 1); return 1; }
    size_t sent = 0;
    do {
        if (pump(p, remaining(until), bytes, length, &sent, 0) < 0)
            return io_error(L, p, errno);
        if (sent == length) { lua_pushboolean(L, 1); return 1; }
        if (reap(p) < 0) return io_error(L, p, errno);
        if (p->in < 0) return pair(L, "eof");
    } while (remaining(until));
    /* A partially written frame cannot be reused by the next request. */
    close_process(p);
    return pair(L, "timeout");
}

static int receive_lua(lua_State *L) {
    struct process *p = check_process(L);
    int64_t until = deadline(L, 2);
    lua_Integer maximum = luaL_optinteger(L, 3, (lua_Integer)p->output_limit);
    luaL_argcheck(L, maximum > 0 && (uintmax_t)maximum <= SIZE_MAX, 3,
                  "maxBytes must be a positive byte count");
    for (;;) {
        char *newline = p->output_size ? memchr(p->output, '\n', p->output_size) : NULL;
        size_t size = newline ? (size_t)(newline - p->output) : p->output_size;
        if (size > (size_t)maximum) {
            close_process(p);
            return luaL_error(L, "process line exceeds maxBytes");
        }
        if (newline || (p->out < 0 && size)) {
            lua_pushlstring(L, p->output, size);
            size_t consumed = size + (newline ? 1 : 0);
            memmove(p->output, p->output + consumed, p->output_size - consumed);
            p->output_size -= consumed;
            return 1;
        }
        if (p->out < 0) return pair(L, "eof");
        size_t ignored = 0;
        if (pump(p, remaining(until), NULL, 0, &ignored, 0) < 0)
            return io_error(L, p, errno);
        if (reap(p) < 0) return io_error(L, p, errno);
        if (!remaining(until)) {
            newline = p->output_size ? memchr(p->output, '\n', p->output_size) : NULL;
            if (!newline && p->out >= 0) return pair(L, "timeout");
        }
    }
}

static int stderr_lua(lua_State *L) {
    struct process *p = check_process(L);
    /* Bound work as well as storage when a child continuously logs. */
    for (int i = 0; p->err >= 0 && i < 16; ++i) {
        struct pollfd fd = {p->err, POLLIN, 0};
        if (poll(&fd, 1, 0) <= 0) break;
        if (drain(p, &p->err, 1, 0) < 0) return io_error(L, p, errno);
    }
    lua_pushlstring(L, p->errors ? p->errors : "", p->error_size);
    return 1;
}

static int status_lua(lua_State *L) {
    struct process *p = check_process(L);
    if (reap(p) < 0) return luaL_error(L, "process status: %s", strerror(errno));
    if (p->exited) lua_pushinteger(L, p->code);
    else lua_pushnil(L);
    return 1;
}

static size_t byte_option(lua_State *L, const char *name, size_t fallback, int allow_zero) {
    lua_getfield(L, 1, name);
    lua_Integer value = luaL_optinteger(L, -1, (lua_Integer)fallback);
    if (value < (allow_zero ? 0 : 1) || (uintmax_t)value > SIZE_MAX)
        luaL_error(L, "%s must be a valid byte count", name);
    lua_pop(L, 1);
    return (size_t)value;
}

static int plain_string(lua_State *L, int index) {
    size_t size;
    if (lua_type(L, index) != LUA_TSTRING) return 0;
    const char *value = lua_tolstring(L, index, &size);
    return !memchr(value, '\0', size);
}

static void free_strings(char **values) {
    if (!values) return;
    for (size_t i = 0; values[i]; ++i) free(values[i]);
    free(values);
}

static int pipe_pair(int fds[2]) {
    if (pipe(fds) < 0) return -1;
    for (int i = 0; i < 2; ++i) {
        if (fds[i] < 3) {
            int next = fcntl(fds[i], F_DUPFD, 3);
            if (next < 0) return -1;
            close(fds[i]);
            fds[i] = next;
        }
        if (fcntl(fds[i], F_SETFD, FD_CLOEXEC) < 0) return -1;
    }
    return 0;
}

static int spawn_lua(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    size_t output_limit = byte_option(L, "stdoutBytes", DEFAULT_STDOUT_BYTES, 0);
    size_t error_limit = byte_option(L, "stderrBytes", DEFAULT_STDERR_BYTES, 1);
    lua_getfield(L, 1, "argv");
    luaL_checktype(L, -1, LUA_TTABLE);
    int arguments = lua_gettop(L);
    size_t count = lua_rawlen(L, arguments);
    luaL_argcheck(L, count > 0 && count < SIZE_MAX / sizeof(char *), 1, "argv must not be empty");
    for (size_t i = 0; i < count; ++i) {
        lua_rawgeti(L, arguments, (lua_Integer)i + 1);
        if (!plain_string(L, -1) || (i == 0 && lua_rawlen(L, -1) == 0))
            return luaL_error(L, "argv must contain strings without NUL bytes and name a program");
        lua_pop(L, 1);
    }
    lua_getfield(L, 1, "cwd");
    if (!lua_isnil(L, -1) && !plain_string(L, -1))
        return luaL_error(L, "cwd must be a string without NUL bytes");
    const char *cwd = lua_tostring(L, -1);
    lua_getfield(L, 1, "env");
    int environment = lua_gettop(L);
    int inherit = lua_isnil(L, environment);
    size_t env_count = 0;
    if (!inherit) {
        luaL_checktype(L, environment, LUA_TTABLE);
        lua_pushnil(L);
        while (lua_next(L, environment)) {
            if (!plain_string(L, -2) || !plain_string(L, -1) ||
                lua_rawlen(L, -2) == 0 || strchr(lua_tostring(L, -2), '='))
                return luaL_error(L, "env must map nonempty names to strings without NUL bytes or '=' in names");
            ++env_count;
            lua_pop(L, 1);
        }
    }
    struct process *p = lua_newuserdatauv(L, sizeof *p, 0);
    memset(p, 0, sizeof *p);
    p->in = p->out = p->err = -1;
    p->output_limit = output_limit;
    p->error_limit = error_limit;
    luaL_setmetatable(L, PROCESS_META);
    char **argv = calloc(count + 1, sizeof *argv);
    char **env = inherit ? NULL : calloc(env_count + 1, sizeof *env);
    int error = ENOMEM;
    if (!argv || (!inherit && !env)) goto failed;
    for (size_t i = 0; i < count; ++i) {
        lua_rawgeti(L, arguments, (lua_Integer)i + 1);
        argv[i] = strdup(lua_tostring(L, -1));
        lua_pop(L, 1);
        if (!argv[i]) goto failed;
    }
    if (!inherit) {
        size_t i = 0;
        lua_pushnil(L);
        while (lua_next(L, environment)) {
            size_t key_size, value_size;
            const char *key = lua_tolstring(L, -2, &key_size);
            const char *value = lua_tolstring(L, -1, &value_size);
            if (key_size > SIZE_MAX - value_size - 2) { lua_pop(L, 2); goto failed; }
            env[i] = malloc(key_size + value_size + 2);
            if (!env[i]) { lua_pop(L, 2); goto failed; }
            memcpy(env[i], key, key_size);
            env[i][key_size] = '=';
            memcpy(env[i] + key_size + 1, value, value_size + 1);
            ++i;
            lua_pop(L, 1);
        }
    }
    if (error_limit && !(p->errors = malloc(error_limit))) goto failed;
    int fds[6] = {-1, -1, -1, -1, -1, -1};
    for (int i = 0; i < 6; i += 2) {
        if (pipe_pair(fds + i) < 0) { error = errno; goto pipes_failed; }
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    if ((error = posix_spawn_file_actions_init(&actions))) goto pipes_failed;
    if ((error = posix_spawnattr_init(&attributes))) goto actions_failed;
    int ends[3] = {fds[0], fds[3], fds[5]};
    for (int i = 0; i < 3; ++i)
        if ((error = posix_spawn_file_actions_adddup2(&actions, ends[i], i))) goto attributes_failed;
    if (cwd) {
#if defined(__NetBSD__) || (defined(__APPLE__) && __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ >= 260000)
        error = posix_spawn_file_actions_addchdir(&actions, cwd);
#else
        error = posix_spawn_file_actions_addchdir_np(&actions, cwd);
#endif
        if (error) goto attributes_failed;
    }
    /* Do not hand the child any open model sockets or unrelated files. */
    long open_limit = sysconf(_SC_OPEN_MAX);
    if (open_limit < 0) { error = errno ? errno : EINVAL; goto attributes_failed; }
    int descriptor_limit = open_limit > INT_MAX ? INT_MAX : (int)open_limit;
    for (int fd = 3; fd < descriptor_limit; ++fd)
        if (fcntl(fd, F_GETFD) >= 0 &&
            (error = posix_spawn_file_actions_addclose(&actions, fd))) goto attributes_failed;
    sigset_t empty, defaults;
    sigemptyset(&empty);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE);
    sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGTERM);
    if ((error = posix_spawnattr_setsigmask(&attributes, &empty))) goto attributes_failed;
    if ((error = posix_spawnattr_setsigdefault(&attributes, &defaults))) goto attributes_failed;
    if ((error = posix_spawnattr_setpgroup(&attributes, 0))) goto attributes_failed;
    if ((error = posix_spawnattr_setflags(&attributes,
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))) goto attributes_failed;
    int parent[3] = {fds[1], fds[2], fds[4]};
    for (int i = 0; i < 3; ++i) {
        int flags = fcntl(parent[i], F_GETFL);
        if (flags < 0 || fcntl(parent[i], F_SETFL, flags | O_NONBLOCK) < 0) {
            error = errno;
            goto attributes_failed;
        }
    }
    /* A broken stdin is an I/O result, never a signal killing the host. */
    struct sigaction ignore;
    memset(&ignore, 0, sizeof ignore);
    ignore.sa_handler = SIG_IGN;
    sigemptyset(&ignore.sa_mask);
    if (sigaction(SIGPIPE, &ignore, NULL) < 0) { error = errno; goto attributes_failed; }
    sigset_t previous;
    block_signals(&previous);
    pid_t pid;
    error = posix_spawnp(&pid, argv[0], &actions, &attributes, argv, inherit ? environ : env);
    if (!error) {
        p->group = (sig_atomic_t)pid;
        p->in = parent[0]; p->out = parent[1]; p->err = parent[2];
        p->next = children;
        children = p;
    }
    sigprocmask(SIG_SETMASK, &previous, NULL);
    if (!error) {
        for (int i = 0; i < 3; ++i) close(ends[i]);
        posix_spawnattr_destroy(&attributes);
        posix_spawn_file_actions_destroy(&actions);
        free_strings(argv);
        free_strings(env);
        return 1;
    }
attributes_failed:
    posix_spawnattr_destroy(&attributes);
actions_failed:
    posix_spawn_file_actions_destroy(&actions);
pipes_failed:
    for (int i = 0; i < 6; ++i) if (fds[i] >= 0) close(fds[i]);
failed:
    free_strings(argv);
    free_strings(env);
    return luaL_error(L, "spawn: %s", strerror(error));
}

int luaopen_asenta_process(lua_State *L) {
    static const luaL_Reg methods[] = {
        {"send", send_lua}, {"receive", receive_lua}, {"stderr", stderr_lua},
        {"status", status_lua}, {"close", close_lua},
        {"__close", close_lua}, {"__gc", collect_lua}, {NULL, NULL}
    };
    luaL_newmetatable(L, PROCESS_META);
    luaL_setfuncs(L, methods, 0);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushcfunction(L, spawn_lua);
    lua_setfield(L, -2, "spawn");
    return 1;
}
