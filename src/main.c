#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#define _NETBSD_SOURCE
#include "host.h"
#include <lauxlib.h>
#include <lualib.h>
#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
#ifdef __NetBSD__
#include <sys/sysctl.h>
#endif
#include <time.h>

struct memory { size_t live, peak; };
static char program_directory[PATH_MAX];
static int supervised, draining, supervisor_stopped;

/* Queue boundaries poll commands without changing stdin's file flags.
 * SIGTERM keeps the existing immediate child cleanup for blocked I/O. */
static int supervision(lua_State *L) {
    static char line[16];
    static size_t length;
    if (supervised && !supervisor_stopped) {
        struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN};
        while (poll(&input, 1, 0) > 0) {
            if (input.revents & (POLLERR | POLLNVAL)) { supervisor_stopped = 1; break; }
            if (!(input.revents & (POLLIN | POLLHUP))) break;
            char bytes[256];
            ssize_t count = read(STDIN_FILENO, bytes, sizeof bytes);
            if (count == 0) { supervisor_stopped = 1; break; }
            if (count < 0) {
                if (errno == EINTR) continue;
                if (errno != EAGAIN && errno != EWOULDBLOCK) supervisor_stopped = 1;
                break;
            }
            for (ssize_t i = 0; i < count; ++i) {
                if (bytes[i] == '\n') {
                    if ((length == 5 && !memcmp(line, "drain", 5)) ||
                        (length == 6 && !memcmp(line, "drain\r", 6))) draining = 1;
                    length = 0;
                } else if (length < sizeof line) line[length++] = bytes[i];
            }
        }
    }
    lua_newtable(L);
    lua_pushboolean(L, draining); lua_setfield(L, -2, "draining");
    lua_pushboolean(L, supervisor_stopped); lua_setfield(L, -2, "stopped");
    return 1;
}

/* Resolve the executable, not the working directory or a caller's symlink.
 * The PATH fallback also covers NetBSD installations without procfs. */
static int find_program(const char *command) {
    char path[PATH_MAX], resolved[PATH_MAX];
#ifdef __APPLE__
    uint32_t size = sizeof path;
    if (!_NSGetExecutablePath(path, &size) && realpath(path, resolved)) goto found;
#endif
#ifdef __linux__
    ssize_t size = readlink("/proc/self/exe", path, sizeof path - 1);
    if (size > 0 && (size_t)size < sizeof path - 1) {
        path[size] = '\0';
        if (realpath(path, resolved)) goto found;
    }
#endif
    if (strchr(command, '/')) {
        if (realpath(command, resolved)) goto found;
        return 0;
    }
    const char *search = getenv("PATH");
    if (!search) search = "/usr/bin:/bin";
    while (1) {
        const char *end = strchr(search, ':');
        size_t length = end ? (size_t)(end - search) : strlen(search);
        if (length < sizeof path && strlen(command) + length + 2 <= sizeof path) {
            if (length) snprintf(path, sizeof path, "%.*s/%s", (int)length, search, command);
            else snprintf(path, sizeof path, "%s", command);
            if (!access(path, X_OK) && realpath(path, resolved)) goto found;
        }
        if (!end) return 0;
        search = end + 1;
    }
found:
    *strrchr(resolved, '/') = '\0';
    snprintf(program_directory, sizeof program_directory, "%s", resolved[0] ? resolved : "/");
    return 1;
}

static void *allocate(void *ud, void *ptr, size_t old, size_t size) {
    struct memory *m = ud;
    if (!ptr) old = 0;
    if (!size) { free(ptr); m->live -= old; return NULL; }
    void *next = realloc(ptr, size);
    if (next) {
        m->live = m->live - old + size;
        if (m->live > m->peak) m->peak = m->live;
    }
    return next;
}

static int stats(lua_State *L) {
    void *ud;
    lua_getallocf(L, &ud);
    struct memory *m = ud;
    struct rusage usage = {0};
    getrusage(RUSAGE_SELF, &usage);
    lua_newtable(L);
    lua_pushinteger(L, (lua_Integer)m->live); lua_setfield(L, -2, "luaBytes");
    lua_pushinteger(L, (lua_Integer)m->peak); lua_setfield(L, -2, "luaPeakBytes");
    long rss = usage.ru_maxrss;
#ifndef __APPLE__
    rss *= 1024;
#endif
    lua_pushinteger(L, rss); lua_setfield(L, -2, "rusagePeakBytes");
#ifdef __linux__
    /* VmHWM excludes the Go test driver's memory briefly inherited at fork. */
    FILE *status = fopen("/proc/self/status", "r");
    if (status) {
        char line[128];
        long kb;
        while (fgets(line, sizeof line, status))
            if (sscanf(line, "VmHWM: %ld kB", &kb) == 1) rss = kb * 1024;
        fclose(status);
    }
#endif
#ifdef __NetBSD__
    /* ru_maxrss survives fork/exec here and may describe the test launcher.
     * Current kernel RSS is meaningful; a lifetime peak needs outside sampling. */
    struct kinfo_proc2 process;
    size_t size = sizeof process;
    int mib[] = {CTL_KERN, KERN_PROC2, KERN_PROC_PID, getpid(), sizeof process, 1};
    if (!sysctl(mib, 6, &process, &size, NULL, 0)) {
        lua_pushinteger(L, (lua_Integer)process.p_vm_rssize * sysconf(_SC_PAGESIZE));
        lua_setfield(L, -2, "rssBytes");
    }
#else
    lua_pushinteger(L, rss); lua_setfield(L, -2, "peakRssBytes");
#endif
    lua_pushstring(L, curl_version()); lua_setfield(L, -2, "transport");
    return 1;
}

static int identifier(lua_State *L) {
    unsigned char raw[16];
    char hex[33];
    FILE *file = fopen("/dev/urandom", "rb");
    if (!file) return luaL_error(L, "cannot open random source");
    size_t n = fread(raw, 1, sizeof raw, file);
    fclose(file);
    if (n != sizeof raw) return luaL_error(L, "cannot read random source");
    for (size_t i = 0; i < sizeof raw; ++i) snprintf(hex + i * 2, 3, "%02x", raw[i]);
    lua_pushstring(L, hex);
    return 1;
}

static int monotonic_ms(lua_State *L) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now))
        return luaL_error(L, "read monotonic clock: %s", strerror(errno));
    lua_pushinteger(L, (lua_Integer)now.tv_sec * 1000 + now.tv_nsec / 1000000);
    return 1;
}

static int sleep_ms(lua_State *L) {
    lua_Integer ms = luaL_checkinteger(L, 1);
    luaL_argcheck(L, ms >= 0, 1, "sleep duration must not be negative");
    struct timespec delay = {.tv_sec = (time_t)(ms / 1000),
                            .tv_nsec = (long)(ms % 1000) * 1000000};
    while (nanosleep(&delay, &delay)) {
        if (errno != EINTR) return luaL_error(L, "sleep: %s", strerror(errno));
    }
    return 0;
}

static int log_message(lua_State *L) {
    host_log(0, luaL_checkstring(L, 1));
    return 0;
}

static int core_module(lua_State *L) {
    const luaL_Reg functions[] = {
        {"identifier", identifier}, {"stats", stats},
        {"monotonic_ms", monotonic_ms}, {"sleep", sleep_ms},
        {"supervision", supervision}, {"log", log_message}, {NULL, NULL}
    };
    luaL_newlib(L, functions);
    lua_pushinteger(L, 1); lua_setfield(L, -2, "apiVersion");
    if (program_directory[0]) {
        lua_pushstring(L, program_directory); lua_setfield(L, -2, "programDir");
    }
    return 1;
}

static int http_module(lua_State *L) {
    const luaL_Reg functions[] = {{"request", host_http}, {NULL, NULL}};
    luaL_newlib(L, functions);
    return 1;
}

static void terminate(int signal_number) {
    host_process_signal(signal_number);
    host_bluetooth_signal(signal_number);
    host_service_release();
    signal(signal_number, SIG_DFL);
    raise(signal_number);
}

int main(int argc, char **argv) {
    if (host_service_open()) {
        char message[256];
        snprintf(message, sizeof message, "Cannot initialize agent service: %s", strerror(errno));
        host_log(1, message);
        return 1;
    }
    const char *supervisor = getenv("OXTORG_SUPERVISED");
    supervised = supervisor && !strcmp(supervisor, "1");
    int explicit_script = argc > 1 && argv[1][0] != '-';
    int located = find_program(argv[0]);
    char application[PATH_MAX];
    const char *script = explicit_script ? argv[1] : application;
    if (!explicit_script) {
        if (!located || snprintf(application, sizeof application, "%s/oxtorg-agent.lua", program_directory) >= (int)sizeof application) {
            host_log(1, "Cannot locate the application beside this executable");
            return 1;
        }
    }
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) return 1;
    struct memory memory = {0};
    lua_State *L = lua_newstate(allocate, &memory);
    if (!L) { curl_global_cleanup(); return 1; }
    luaL_openlibs(L);
    luaL_requiref(L, "asenta.core", core_module, 0); lua_pop(L, 1);
    luaL_requiref(L, "asenta.http", http_module, 0); lua_pop(L, 1);
    luaL_requiref(L, "asenta.fs", luaopen_asenta_fs, 0); lua_pop(L, 1);
    luaL_requiref(L, "asenta.process", luaopen_asenta_process, 0); lua_pop(L, 1);
    luaL_requiref(L, "asenta.equipment", luaopen_asenta_equipment, 0); lua_pop(L, 1);
    luaL_requiref(L, "asenta.bluetooth", luaopen_asenta_bluetooth, 0); lua_pop(L, 1);
    luaL_requiref(L, "asenta.obd", luaopen_asenta_obd, 0); lua_pop(L, 1);
    struct sigaction action = {0};
    action.sa_handler = terminate;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);
    lua_newtable(L);
    lua_pushstring(L, script); lua_rawseti(L, -2, 0);
    for (int i = explicit_script ? 2 : 1; i < argc; ++i) {
        lua_pushstring(L, argv[i]); lua_rawseti(L, -2, i - (explicit_script ? 1 : 0));
    }
    lua_setglobal(L, "arg");
    lua_newtable(L);
    lua_pushcfunction(L, host_http); lua_setfield(L, -2, "request");
    lua_pushcfunction(L, identifier); lua_setfield(L, -2, "identifier");
    lua_pushcfunction(L, stats); lua_setfield(L, -2, "stats");
    lua_setglobal(L, "host");
    int failed = luaL_loadfile(L, script) || lua_pcall(L, 0, explicit_script ? 0 : 1, 0);
    /* The package registers lazy module loaders and returns its entry point.
     * Release the registration chunk before entering the long-running queue. */
    if (!failed && !explicit_script) {
        lua_gc(L, LUA_GCCOLLECT);
        failed = lua_pcall(L, 0, 0, 0);
    }
    if (failed) {
        if (lua_istable(L, -1)) lua_getfield(L, -1, "message");
        const char *message = lua_tostring(L, -1);
        host_log(1, message ? message : "Lua execution failed");
    }
    host_process_close();
    host_http_close();
    lua_close(L);
    curl_global_cleanup();
    return failed ? 1 : 0;
}
