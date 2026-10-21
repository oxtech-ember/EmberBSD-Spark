#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#define _NETBSD_SOURCE
#define _DEFAULT_SOURCE
#include "host.h"
#include <lauxlib.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#if defined(__NetBSD__) || defined(__APPLE__)
#include <sys/sysctl.h>
#endif
#ifdef __NetBSD__
#include <sys/envsys.h>
#include <uvm/uvm_extern.h>
#include <prop/proplib.h>
#endif
#ifdef __APPLE__
#include <mach/mach.h>
#endif

/* The worker owns no Lua objects and never calls Lua. Samples contain numeric
 * readings and interned sensor names, not repeated strings or JSON documents.
 * The fixed native snapshot is private to this host version; incompatible
 * snapshots are reported and left intact rather than silently discarded. */
#define EQUIPMENT_TYPE "asenta.equipment.handle"
#define MAX_HISTORY 10000
#define MAX_TEMPERATURES 16
#define MAX_NAMES 64
#define NAME_BYTES 128
#define PATH_BYTES 1024
#define JOURNAL_WINDOW (4 * 1024 * 1024)
#define JOURNAL_LINE (64 * 1024)
#define JOURNAL_OUTPUT (256 * 1024)
#define INVALID_SOURCE 65536
#define SOURCE_CAPACITY 65537
#define SENSOR_NAME_LONG 65538
#define DIR_FLAGS (O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

struct sample {
    int64_t seconds, nanoseconds, uptime, total_kb, available_kb;
    double load[3], celsius[MAX_TEMPERATURES];
    int errors[4];
    uint8_t names[MAX_TEMPERATURES], temperatures;
};
struct equipment {
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    int initialized, thread_started, stop, stopped, closed;
    int capacity, count, start, name_count, persisted;
    uint64_t discarded;
    double interval, temperature_limit, load_limit, memory_limit;
    struct sample *samples;
    char names[MAX_NAMES][NAME_BYTES];
    char proc[PATH_BYTES], sys[PATH_BYTES], syslog[PATH_BYTES];
    char units[4096], store_name[256], store_error[256];
    int store_fd;
};
struct store_header {
    char magic[8];
    uint32_t byte_order, record_bytes, count, names;
    uint64_t discarded;
};
static const char *const sources[] = {"load", "uptime", "memory", "temperature"};

static void number_field(lua_State *L, const char *key, double value) {
    lua_pushnumber(L, value); lua_setfield(L, -2, key);
}
static void integer_field(lua_State *L, const char *key, lua_Integer value) {
    lua_pushinteger(L, value); lua_setfield(L, -2, key);
}
static void string_field(lua_State *L, const char *key, const char *value) {
    lua_pushstring(L, value); lua_setfield(L, -2, key);
}
static void boolean_field(lua_State *L, const char *key, int value) {
    lua_pushboolean(L, value); lua_setfield(L, -2, key);
}
static void array(lua_State *L) {
    lua_newtable(L); lua_newtable(L);
    string_field(L, "__jsontype", "array"); lua_setmetatable(L, -2);
}
static void timestamp(lua_State *L, int64_t seconds, int64_t nanoseconds) {
    time_t value = (time_t)seconds;
    struct tm utc;
    char text[64], date[40];
    if (!gmtime_r(&value, &utc) || !strftime(date, sizeof date, "%Y-%m-%dT%H:%M:%S", &utc)) {
        lua_pushliteral(L, "1970-01-01T00:00:00Z"); return;
    }
    snprintf(text, sizeof text, "%s.%09ldZ", date, (long)nanoseconds);
    lua_pushstring(L, text);
}
static double sample_time(const struct sample *s) {
    return (double)s->seconds + (double)s->nanoseconds / 1e9;
}
static double current_time(void) {
    struct timespec t; clock_gettime(CLOCK_REALTIME, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}
static const char *error_text(int code) {
    if (code == INVALID_SOURCE) return "source reading is missing or invalid";
    if (code == SOURCE_CAPACITY) return "sensor count exceeds native collector capacity";
    if (code == SENSOR_NAME_LONG) return "sensor name exceeds native collector capacity";
    return strerror(code);
}
static int read_text(const char *path, char *text, size_t capacity) {
    FILE *file = fopen(path, "r");
    if (!file) return errno;
    size_t n = fread(text, 1, capacity - 1, file);
    int code = ferror(file) ? errno : 0;
    if (!code && !feof(file)) { int extra = fgetc(file); if (extra != EOF) code = EFBIG; }
    fclose(file); text[n] = '\0'; return code;
}
static void trim(char *text) {
    size_t n = strlen(text);
    while (n && isspace((unsigned char)text[n - 1])) text[--n] = '\0';
}
static int path_join(char *out, size_t capacity, const char *root, const char *name) {
    int n = snprintf(out, capacity, "%s/%s", root, name);
    return n < 0 || (size_t)n >= capacity ? ENAMETOOLONG : 0;
}
static void add_temperature(struct equipment *e, struct sample *s, const char *name, double value) {
    if (!isfinite(value)) { s->errors[3] = INVALID_SOURCE; return; }
    if (strlen(name) >= NAME_BYTES) { s->errors[3] = SENSOR_NAME_LONG; return; }
    if (s->temperatures >= MAX_TEMPERATURES) { s->errors[3] = SOURCE_CAPACITY; return; }
    int index = 0;
    while (index < e->name_count && strcmp(e->names[index], name)) ++index;
    if (index == e->name_count) {
        if (index == MAX_NAMES) { s->errors[3] = SOURCE_CAPACITY; return; }
        strcpy(e->names[e->name_count++], name);
    }
    /* Sorted names keep the response stable even when the kernel reorders. */
    int at = s->temperatures++;
    while (at && strcmp(e->names[s->names[at - 1]], name) > 0) {
        s->names[at] = s->names[at - 1]; s->celsius[at] = s->celsius[at - 1]; --at;
    }
    s->names[at] = (uint8_t)index; s->celsius[at] = value;
}
static void proc_reading(struct equipment *e, struct sample *s) {
    char path[PATH_BYTES], text[16384];
    const char *root = *e->proc ? e->proc : "/proc";
    int code = path_join(path, sizeof path, root, "loadavg");
    if (!code) code = read_text(path, text, sizeof text);
    if (code) s->errors[0] = code;
    else if (sscanf(text, "%lf %lf %lf", &s->load[0], &s->load[1], &s->load[2]) != 3)
        s->errors[0] = INVALID_SOURCE;
    for (int i = 0; i < 3; ++i) if (!isfinite(s->load[i]) || s->load[i] < 0) s->errors[0] = INVALID_SOURCE;
    if (s->errors[0]) memset(s->load, 0, sizeof s->load);
    code = path_join(path, sizeof path, root, "uptime");
    if (!code) code = read_text(path, text, sizeof text);
    double uptime = 0;
    if (code) s->errors[1] = code;
    else if (sscanf(text, "%lf", &uptime) != 1 || !isfinite(uptime) || uptime < 0 || uptime >= (double)INT64_MAX)
        s->errors[1] = INVALID_SOURCE;
    else s->uptime = (int64_t)uptime;
    code = path_join(path, sizeof path, root, "meminfo");
    if (!code) code = read_text(path, text, sizeof text);
    if (code) s->errors[2] = code;
    else {
        int present = 0; long long total = 0, available = 0, values[6];
        char *save = NULL;
        for (char *line = strtok_r(text, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
            if (!strncmp(line, "MemTotal:", 9)) {
                if (sscanf(line + 9, "%lld", &total) != 1) total = 0;
            } else if (!strncmp(line, "MemAvailable:", 13)) {
                present = sscanf(line + 13, "%lld", &available) == 1 ? 2 : -1;
            } else if (!strncmp(line, "Mem:", 4) && present < 2) {
                if (sscanf(line + 4, "%lld %lld %lld %lld %lld %lld", &values[0], &values[1], &values[2], &values[3], &values[4], &values[5]) == 6) {
                    int valid = 1;
                    for (int j = 0; j < 6; ++j) if (values[j] < 0) valid = 0;
                    if (valid && values[2] <= INT64_MAX - values[4]) {
                        available = (values[2] + values[4]) / 1024; present = 1;
                    }
                }
            }
        }
        if (present <= 0 || total <= 0 || available < 0 || available > total) s->errors[2] = INVALID_SOURCE;
        else { s->total_kb = total; s->available_kb = available; }
    }
}
static void sys_temperatures(struct equipment *e, struct sample *s) {
    char path[PATH_BYTES], text[256], name[NAME_BYTES];
    if (path_join(path, sizeof path, *e->sys ? e->sys : "/sys", "class/thermal/thermal_zone*")) {
        s->errors[3] = ENAMETOOLONG; return;
    }
    glob_t zones; memset(&zones, 0, sizeof zones);
    int found = glob(path, 0, NULL, &zones);
    if (found && found != GLOB_NOMATCH) s->errors[3] = EIO;
    if (!found) for (size_t i = 0; i < zones.gl_pathc; ++i) {
        const char *base = strrchr(zones.gl_pathv[i], '/');
        snprintf(name, sizeof name, "%s", base ? base + 1 : zones.gl_pathv[i]);
        if (!path_join(path, sizeof path, zones.gl_pathv[i], "type") && !read_text(path, text, sizeof text)) {
            trim(text);
            if (strlen(text) >= sizeof name) { s->errors[3] = SENSOR_NAME_LONG; continue; }
            strcpy(name, text);
        }
        int code = path_join(path, sizeof path, zones.gl_pathv[i], "temp");
        if (!code) code = read_text(path, text, sizeof text);
        char *end; errno = 0; double milli = code ? 0 : strtod(text, &end);
        if (code) { s->errors[3] = code; continue; }
        while (isspace((unsigned char)*end)) ++end;
        if (errno || end == text || *end || !isfinite(milli)) { s->errors[3] = INVALID_SOURCE; continue; }
        add_temperature(e, s, name, milli / 1000);
    }
    globfree(&zones);
}
#ifdef __NetBSD__
static void netbsd_temperatures(struct equipment *e, struct sample *s) {
    int fd = open("/dev/sysmon", O_RDONLY | O_CLOEXEC);
    if (fd < 0) { s->errors[3] = errno; return; }
    prop_dictionary_t dictionary = NULL;
    int code = prop_dictionary_recv_ioctl(fd, ENVSYS_GETDICTIONARY, &dictionary);
    close(fd);
    if (code) { s->errors[3] = code; return; }
    prop_object_iterator_t iterator = prop_dictionary_iterator(dictionary);
    if (!iterator) { prop_object_release(dictionary); s->errors[3] = ENOMEM; return; }
    prop_dictionary_keysym_t key;
    while ((key = prop_object_iterator_next(iterator)) != NULL) {
        const char *device = prop_dictionary_keysym_value(key);
        prop_object_t sensors = prop_dictionary_get(dictionary, device);
        if (prop_object_type(sensors) != PROP_TYPE_ARRAY) continue;
        for (unsigned int i = 0; i < prop_array_count(sensors); ++i) {
            prop_object_t sensor = prop_array_get(sensors, i);
            if (prop_object_type(sensor) != PROP_TYPE_DICTIONARY) continue;
            const char *type, *state, *description;
            int64_t value;
            if (!prop_dictionary_get_cstring_nocopy(sensor, "type", &type) || strcmp(type, "Temperature") ||
                !prop_dictionary_get_cstring_nocopy(sensor, "state", &state) || strcmp(state, "valid") ||
                !prop_dictionary_get_int64(sensor, "cur-value", &value) || value < 0) continue;
            if (!prop_dictionary_get_cstring_nocopy(sensor, "description", &description) || !*description)
                if (!prop_dictionary_get_cstring_nocopy(sensor, "index", &description)) description = "";
            char name[NAME_BYTES];
            int n = snprintf(name, sizeof name, "%s:%s", device, description);
            if (n < 0 || n >= (int)sizeof name) { s->errors[3] = SENSOR_NAME_LONG; continue; }
            add_temperature(e, s, name, (double)(value - 273150000) / 1e6);
        }
    }
    prop_object_iterator_release(iterator); prop_object_release(dictionary);
}
#endif
static void observe(struct equipment *e, struct sample *s) {
    memset(s, 0, sizeof *s);
    struct timespec now; clock_gettime(CLOCK_REALTIME, &now);
    s->seconds = now.tv_sec; s->nanoseconds = now.tv_nsec;
    if (*e->proc) { proc_reading(e, s); sys_temperatures(e, s); return; }
#if defined(__NetBSD__) || defined(__APPLE__)
    if (getloadavg(s->load, 3) != 3) s->errors[0] = errno ? errno : EIO;
    struct timeval boot; size_t length = sizeof boot;
    int mib[] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &boot, &length, NULL, 0)) s->errors[1] = errno;
    else s->uptime = now.tv_sec >= boot.tv_sec ? now.tv_sec - boot.tv_sec : 0;
#ifdef __NetBSD__
    struct uvmexp_sysctl vm; length = sizeof vm;
    int memory_mib[] = {CTL_VM, VM_UVMEXP2};
    if (sysctl(memory_mib, 2, &vm, &length, NULL, 0)) s->errors[2] = errno;
    else {
        s->total_kb = vm.npages * vm.pagesize / 1024;
        s->available_kb = (vm.free + vm.filepages) * vm.pagesize / 1024;
    }
    netbsd_temperatures(e, s);
#else
    uint64_t total; length = sizeof total;
    vm_statistics64_data_t vm; mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    mach_port_t host = mach_host_self(); vm_size_t page_size;
    if (sysctlbyname("hw.memsize", &total, &length, NULL, 0) ||
        host_page_size(host, &page_size) != KERN_SUCCESS ||
        host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS)
        s->errors[2] = EIO;
    else {
        s->total_kb = (int64_t)(total / 1024);
        s->available_kb = ((int64_t)vm.free_count + vm.inactive_count) * page_size / 1024;
    }
    mach_port_deallocate(mach_task_self(), host);
#endif
#else
    proc_reading(e, s); sys_temperatures(e, s);
#endif
    if (!s->errors[2] && (s->total_kb <= 0 || s->available_kb < 0 || s->available_kb > s->total_kb)) {
        s->errors[2] = INVALID_SOURCE; s->total_kb = s->available_kb = 0;
    }
}

static int complete_io(int fd, void *bytes, size_t size, int writing) {
    unsigned char *at = bytes;
    while (size) {
        ssize_t n = writing ? write(fd, at, size) : read(fd, at, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return n < 0 ? errno : EINVAL;
        size -= (size_t)n; at += n;
    }
    return 0;
}
static void storage_error(struct equipment *e, const char *action, int code) {
    e->persisted = 0;
    snprintf(e->store_error, sizeof e->store_error, "%s: %s", action, error_text(code));
}
static int valid_sample(const struct sample *s, unsigned int names) {
    if (s->seconds <= 0 || s->nanoseconds < 0 || s->nanoseconds >= 1000000000 ||
        s->temperatures > MAX_TEMPERATURES || s->uptime < 0 || s->total_kb < 0 ||
        s->available_kb < 0 || s->available_kb > s->total_kb) return 0;
    for (int i = 0; i < 3; ++i) if (!isfinite(s->load[i]) || s->load[i] < 0) return 0;
    for (int i = 0; i < 4; ++i) if (s->errors[i] < 0 || s->errors[i] > SENSOR_NAME_LONG) return 0;
    for (int i = 0; i < s->temperatures; ++i) if (s->names[i] >= names || !isfinite(s->celsius[i])) return 0;
    return 1;
}
static int restore(struct equipment *e) {
    int fd = openat(e->store_fd, e->store_name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return errno == ENOENT ? 0 : errno;
    struct stat st; struct store_header header;
    int code = fstat(fd, &st) ? errno : 0;
    if (!code && (!S_ISREG(st.st_mode) || (st.st_mode & 0077))) code = EPERM;
    if (!code) code = complete_io(fd, &header, sizeof header, 0);
    if (!code && (memcmp(header.magic, "ASENTEQ1", 8) || header.byte_order != 0x12345678 ||
        header.record_bytes != sizeof(struct sample) || header.count > MAX_HISTORY || header.names > MAX_NAMES ||
        header.discarded > (uint64_t)INT64_MAX - MAX_HISTORY ||
        st.st_size != (off_t)(sizeof header + header.names * NAME_BYTES + header.count * sizeof(struct sample)))) code = EINVAL;
    char names[MAX_NAMES][NAME_BYTES];
    if (!code) code = complete_io(fd, names, header.names * NAME_BYTES, 0);
    if (!code) for (unsigned int i = 0; i < header.names; ++i)
        if (!memchr(names[i], '\0', NAME_BYTES)) { code = EINVAL; break; }
    struct sample sample;
    for (unsigned int i = 0; !code && i < header.count; ++i) {
        code = complete_io(fd, &sample, sizeof sample, 0);
        if (!code && !valid_sample(&sample, header.names)) code = EINVAL;
    }
    if (!code) {
        unsigned int skip = header.count > (unsigned)e->capacity ? header.count - (unsigned)e->capacity : 0;
        off_t offset = (off_t)(sizeof header + header.names * NAME_BYTES + skip * sizeof sample);
        if (lseek(fd, offset, SEEK_SET) < 0) code = errno;
        else {
            e->count = (int)(header.count - skip); e->discarded = header.discarded + skip;
            e->name_count = (int)header.names; memcpy(e->names, names, header.names * NAME_BYTES);
            code = complete_io(fd, e->samples, (size_t)e->count * sizeof sample, 0);
            if (code) { e->count = 0; e->discarded = 0; }
            else e->persisted = 1;
        }
    }
    close(fd); return code;
}
static int save(struct equipment *e) {
    struct store_header header = {{0}, 0, 0, 0, 0, 0};
    memcpy(header.magic, "ASENTEQ1", 8); header.byte_order = 0x12345678;
    header.record_bytes = sizeof(struct sample); header.count = e->count;
    header.names = e->name_count; header.discarded = e->discarded;
    char temporary[320];
    snprintf(temporary, sizeof temporary, ".%s.%ld.tmp", e->store_name, (long)getpid());
    int fd = openat(e->store_fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return errno;
    int code = complete_io(fd, &header, sizeof header, 1);
    if (!code) code = complete_io(fd, e->names, (size_t)e->name_count * NAME_BYTES, 1);
    for (int i = 0; !code && i < e->count; ++i)
        code = complete_io(fd, &e->samples[(e->start + i) % e->capacity], sizeof(struct sample), 1);
    if (!code && fsync(fd)) code = errno;
    if (close(fd) && !code) code = errno;
    if (!code && renameat(e->store_fd, temporary, e->store_fd, e->store_name)) code = errno;
    if (!code && fsync(e->store_fd)) code = errno;
    if (code) unlinkat(e->store_fd, temporary, 0);
    return code;
}
static void collect(struct equipment *e) {
    struct sample sample; observe(e, &sample);
    if (e->count == e->capacity) { e->start = (e->start + 1) % e->capacity; ++e->discarded; }
    else ++e->count;
    e->samples[(e->start + e->count - 1) % e->capacity] = sample;
    if (e->store_fd >= 0) {
        int code = save(e);
        if (code) storage_error(e, "write collection history", code);
        else { e->persisted = 1; *e->store_error = '\0'; }
    }
}
static void *worker(void *argument) {
    struct equipment *e = argument;
    pthread_mutex_lock(&e->mutex);
    while (!e->stop) {
        /* Scheduling uses monotonic time; a wall-clock correction changes
         * observation timestamps and gaps without pausing acquisition. */
        struct timespec deadline; clock_gettime(CLOCK_MONOTONIC, &deadline);
        int64_t nanos = (int64_t)(e->interval * 1e9);
        deadline.tv_sec += nanos / 1000000000;
        deadline.tv_nsec += (long)(nanos % 1000000000);
        if (deadline.tv_nsec >= 1000000000) { ++deadline.tv_sec; deadline.tv_nsec -= 1000000000; }
        int code = 0;
        while (!e->stop && code != ETIMEDOUT) {
#ifdef __APPLE__
            struct timespec now, delay; clock_gettime(CLOCK_MONOTONIC, &now);
            delay.tv_sec = deadline.tv_sec - now.tv_sec;
            delay.tv_nsec = deadline.tv_nsec - now.tv_nsec;
            if (delay.tv_nsec < 0) { --delay.tv_sec; delay.tv_nsec += 1000000000; }
            code = delay.tv_sec < 0 ? ETIMEDOUT : pthread_cond_timedwait_relative_np(&e->changed, &e->mutex, &delay);
#else
            code = pthread_cond_timedwait(&e->changed, &e->mutex, &deadline);
#endif
            if (code && code != ETIMEDOUT) e->stop = 1;
        }
        if (!e->stop) collect(e);
    }
    e->stopped = 1; pthread_mutex_unlock(&e->mutex); return NULL;
}
static struct equipment *handle(lua_State *L) {
    struct equipment *e = luaL_checkudata(L, 1, EQUIPMENT_TYPE);
    luaL_argcheck(L, !e->closed, 1, "equipment connection is closed"); return e;
}
static void reading(lua_State *L, const struct sample *s, char names[MAX_TEMPERATURES][NAME_BYTES]) {
    lua_newtable(L);
    number_field(L, "load1", s->load[0]); number_field(L, "load5", s->load[1]); number_field(L, "load15", s->load[2]);
    integer_field(L, "uptimeSeconds", s->uptime); integer_field(L, "memoryTotalKb", s->total_kb);
    integer_field(L, "memoryAvailableKb", s->available_kb); array(L);
    for (int i = 0; i < s->temperatures; ++i) {
        lua_newtable(L); string_field(L, "zone", names[i]); number_field(L, "celsius", s->celsius[i]);
        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "temperatures");
}
static void sample_names(struct equipment *e, const struct sample *s, char names[MAX_TEMPERATURES][NAME_BYTES]) {
    for (int i = 0; i < s->temperatures; ++i) memcpy(names[i], e->names[s->names[i]], NAME_BYTES);
}
static int equipment_state(lua_State *L) {
    struct equipment *e = handle(L); struct sample sample; char names[MAX_TEMPERATURES][NAME_BYTES];
    pthread_mutex_lock(&e->mutex); observe(e, &sample); sample_names(e, &sample, names); pthread_mutex_unlock(&e->mutex);
    if (sample.errors[0]) return luaL_error(L, "read the load: %s", error_text(sample.errors[0]));
    reading(L, &sample, names); return 1;
}
static int stale(struct equipment *e, double now) {
    return e->stopped || (e->count && now - sample_time(&e->samples[(e->start + e->count - 1) % e->capacity]) > 3 * e->interval);
}
static int equipment_history(lua_State *L) {
    struct equipment *e = handle(L);
    lua_Integer limit = luaL_optinteger(L, 2, 100);
    if (limit <= 0) limit = 100;
    if (limit > MAX_HISTORY) limit = MAX_HISTORY;
    int count, capacity, persisted, old; uint64_t discarded; double last = 0, interval;
    char store_error[256];
    pthread_mutex_lock(&e->mutex);
    count = e->count; capacity = e->capacity; persisted = e->persisted; discarded = e->discarded;
    old = stale(e, current_time()); interval = e->interval; strcpy(store_error, e->store_error);
    if (count) last = sample_time(&e->samples[(e->start + count - 1) % capacity]);
    pthread_mutex_unlock(&e->mutex);
    lua_newtable(L);
    string_field(L, "status", count ? (old ? "stale" : "available") : (interval ? "no_data" : "disabled"));
    number_field(L, "intervalSeconds", interval); integer_field(L, "capacity", capacity);
    integer_field(L, "retained", count); integer_field(L, "discarded", (lua_Integer)discarded);
    boolean_field(L, "persisted", persisted); string_field(L, "coverage", "retained_samples_only");
    if (*store_error) string_field(L, "storeError", store_error);
    integer_field(L, "first", (lua_Integer)discarded + (count > limit ? count - limit : 0) + 1);
    integer_field(L, "last", (lua_Integer)discarded + count);
    number_field(L, "staleSince", count && old ? last : 0);
    return 1;
}
static int equipment_sample(lua_State *L) {
    struct equipment *e = handle(L); lua_Integer ordinal = luaL_checkinteger(L, 2);
    struct sample sample; char names[MAX_TEMPERATURES][NAME_BYTES]; int found = 0;
    pthread_mutex_lock(&e->mutex);
    if (ordinal > 0 && (uint64_t)ordinal > e->discarded && (uint64_t)ordinal <= e->discarded + (uint64_t)e->count) {
        sample = e->samples[(e->start + (int)((uint64_t)ordinal - e->discarded - 1)) % e->capacity];
        sample_names(e, &sample, names); found = 1;
    }
    pthread_mutex_unlock(&e->mutex);
    if (!found) return luaL_error(L, "requested history window expired during reading; retry with a smaller limit");
    lua_newtable(L); timestamp(L, sample.seconds, sample.nanoseconds); lua_setfield(L, -2, "observedAt");
    reading(L, &sample, names); lua_setfield(L, -2, "reading"); array(L);
    int n = 0;
    for (int i = 0; i < 4; ++i) if (sample.errors[i]) {
        lua_newtable(L); string_field(L, "source", sources[i]); string_field(L, "error", error_text(sample.errors[i]));
        lua_rawseti(L, -2, ++n);
    }
    lua_setfield(L, -2, "errors"); lua_pushnumber(L, sample_time(&sample)); return 2;
}
struct issue { const char *code; char source[NAME_BYTES + 16], error[256]; };
static int compare_issue(const void *a, const void *b) {
    const struct issue *left = a, *right = b;
    int code = strcmp(left->code, right->code); return code ? code : strcmp(left->source, right->source);
}
static void add_issue(struct issue *issues, int *n, const char *code, const char *source, const char *error) {
    struct issue *out = &issues[(*n)++]; out->code = code;
    snprintf(out->source, sizeof out->source, "%s", source);
    snprintf(out->error, sizeof out->error, "%s", error ? error : "");
}
static int equipment_alerts(lua_State *L) {
    struct equipment *e = handle(L); struct sample sample;
    struct issue issues[MAX_TEMPERATURES + 12]; int n = 0, count, enabled, alert = 0;
    char names[MAX_TEMPERATURES][NAME_BYTES], store_error[256];
    pthread_mutex_lock(&e->mutex);
    enabled = e->interval > 0; count = e->count; strcpy(store_error, e->store_error);
    if (enabled) {
        if (*store_error) add_issue(issues, &n, "storage_error", "history", store_error);
        if (e->stopped) add_issue(issues, &n, "stopped", "collection", NULL);
        if (count) {
            sample = e->samples[(e->start + count - 1) % e->capacity]; sample_names(e, &sample, names);
            for (int i = 0; i < 4; ++i) if (sample.errors[i]) add_issue(issues, &n, "source_error", sources[i], error_text(sample.errors[i]));
            if (stale(e, current_time())) add_issue(issues, &n, "gap", "collection", NULL);
            if (e->load_limit > 0 && !sample.errors[0] && sample.load[0] >= e->load_limit)
                { add_issue(issues, &n, "threshold", "load", NULL); alert = 1; }
            if (e->memory_limit > 0 && !sample.errors[2] && sample.total_kb > 0 &&
                100 * (1 - (double)sample.available_kb / (double)sample.total_kb) >= e->memory_limit)
                { add_issue(issues, &n, "threshold", "memory", NULL); alert = 1; }
            if (e->temperature_limit > 0) {
                if (!sample.temperatures) add_issue(issues, &n, "unavailable", "temperature", NULL);
                for (int i = 0; i < sample.temperatures; ++i) if (sample.celsius[i] >= e->temperature_limit) {
                    char source[NAME_BYTES + 16]; snprintf(source, sizeof source, "temperature:%.*s", NAME_BYTES - 1, names[i]);
                    add_issue(issues, &n, "threshold", source, NULL); alert = 1;
                }
            }
        }
    }
    pthread_mutex_unlock(&e->mutex);
    qsort(issues, (size_t)n, sizeof issues[0], compare_issue);
    lua_newtable(L); boolean_field(L, "enabled", enabled);
    string_field(L, "status", !enabled ? "disabled" : (alert ? "alert" : (n ? "degraded" : (count ? "ok" : "no_data"))));
    if (*store_error) string_field(L, "storeError", store_error);
    lua_newtable(L); number_field(L, "temperatureCelsius", e->temperature_limit);
    number_field(L, "load", e->load_limit); number_field(L, "memoryUsedPercent", e->memory_limit);
    lua_setfield(L, -2, "thresholds"); array(L);
    for (int i = 0; i < n; ++i) {
        lua_newtable(L); string_field(L, "code", issues[i].code); string_field(L, "source", issues[i].source);
        if (*issues[i].error) string_field(L, "error", issues[i].error);
        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "issues"); return 1;
}

static int permitted(struct equipment *e, const char *unit) {
    size_t size = strlen(unit);
    for (const char *at = e->units; *at;) {
        while (*at == ',' || isspace((unsigned char)*at)) ++at;
        const char *end = at; while (*end && *end != ',' && !isspace((unsigned char)*end)) ++end;
        if ((size_t)(end - at) == size && !memcmp(unit, at, size)) return 1;
        at = end;
    }
    return 0;
}
static int line_tag(const char *line, const char *unit) {
    const char *at = line;
    for (int field = 0; field < 4; ++field) {
        while (isspace((unsigned char)*at)) ++at;
        while (*at && !isspace((unsigned char)*at)) ++at;
    }
    while (isspace((unsigned char)*at)) ++at;
    size_t size = strcspn(at, "[: \t\r\n");
    return strlen(unit) == size && !strncmp(at, unit, size);
}
/* Decode only non-ASCII valid Unicode codepoints escaped by NetBSD syslogd. */
static void readable(char *line) {
    char *read_at = line, *write_at = line;
    while (*read_at) {
        if (!strncmp(read_at, "<U+", 3)) {
            char *end; unsigned long code = strtoul(read_at + 3, &end, 16);
            ptrdiff_t digits = end - read_at - 3;
            int hexadecimal = 1;
            for (const char *at = read_at + 3; at < end; ++at)
                if (!isxdigit((unsigned char)*at)) hexadecimal = 0;
            if (hexadecimal && digits >= 2 && digits <= 6 && *end == '>' && code >= 0x80 && code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff)) {
                if (code < 0x800) { *write_at++ = (char)(0xc0 | (code >> 6)); *write_at++ = (char)(0x80 | (code & 63)); }
                else if (code < 0x10000) { *write_at++ = (char)(0xe0 | (code >> 12)); *write_at++ = (char)(0x80 | ((code >> 6) & 63)); *write_at++ = (char)(0x80 | (code & 63)); }
                else { *write_at++ = (char)(0xf0 | (code >> 18)); *write_at++ = (char)(0x80 | ((code >> 12) & 63)); *write_at++ = (char)(0x80 | ((code >> 6) & 63)); *write_at++ = (char)(0x80 | (code & 63)); }
                read_at = end + 1; continue;
            }
        }
        *write_at++ = *read_at++;
    }
    *write_at = '\0';
}
static int equipment_journal(lua_State *L) {
    struct equipment *e = handle(L); size_t unit_length;
    const char *unit = luaL_checklstring(L, 2, &unit_length);
    luaL_argcheck(L, unit_length && !memchr(unit, '\0', unit_length), 2, "unit must be a non-empty name without NUL");
    if (!permitted(e, unit)) return luaL_error(L, "%s is not among the services this installation allows to be read. Allowed: %s", unit, *e->units ? e->units : "none - the installation named no services");
    lua_Integer lines = luaL_optinteger(L, 3, 100); if (lines <= 0) lines = 100; if (lines > 500) lines = 500;
    int fd = open(e->syslog, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return luaL_error(L, "read the log %s: %s", e->syslog, strerror(errno));
    struct stat st; int code = fstat(fd, &st) ? errno : 0;
    if (!code && !S_ISREG(st.st_mode)) code = EINVAL;
    int cut = !code && st.st_size > JOURNAL_WINDOW;
    if (cut && lseek(fd, -JOURNAL_WINDOW, SEEK_END) < 0) code = errno;
    if (code) { close(fd); return luaL_error(L, "read the log: %s", strerror(code)); }
    FILE *file = fdopen(fd, "r");
    if (!file) { code = errno; close(fd); return luaL_error(L, "read the log: %s", strerror(code)); }
    char *line = malloc(JOURNAL_LINE + 2), *output = malloc(JOURNAL_OUTPUT + 1);
    if (!line || !output) { free(line); free(output); fclose(file); return luaL_error(L, "journal allocation failed"); }
    size_t used = 0; int kept = 0, counted = 0, first = 1, truncated = 0;
    while (fgets(line, JOURNAL_LINE + 2, file)) {
        size_t length = strlen(line);
        int whole = length && line[length - 1] == '\n';
        if (!whole && !feof(file)) {
            int byte; while ((byte = fgetc(file)) != '\n' && byte != EOF) {}
            counted = 0; first = 0; continue;
        }
        if (first && cut) { first = 0; counted = 0; continue; }
        first = 0;
        if (line_tag(line, unit)) counted = 1;
        else if (!(counted && line_tag(line, "syslogd") && strstr(line, ": last message repeated "))) { counted = 0; continue; }
        trim(line); readable(line); length = strlen(line);
        while (kept && (kept >= lines || used + length + 1 > JOURNAL_OUTPUT)) {
            char *end = memchr(output, '\n', used); size_t remove = end ? (size_t)(end - output + 1) : used;
            if (kept < lines) truncated = 1;
            memmove(output, output + remove, used - remove); used -= remove; --kept;
        }
        memcpy(output + used, line, length); used += length; output[used++] = '\n'; ++kept;
    }
    code = ferror(file) ? (errno ? errno : EIO) : 0; fclose(file); free(line);
    if (code) { free(output); return luaL_error(L, "read the log: %s", strerror(code)); }
    if (kept) lua_pushlstring(L, output, used);
    else lua_pushfstring(L, "no line under the name %s in %s: older lines are in the rotated files, which are not read", unit, e->syslog);
    free(output); lua_pushboolean(L, truncated); return 2;
}
static void shutdown_equipment(struct equipment *e) {
    if (e->closed) return;
    e->closed = 1;
    if (e->thread_started) {
        pthread_mutex_lock(&e->mutex); e->stop = 1; pthread_cond_signal(&e->changed); pthread_mutex_unlock(&e->mutex);
        pthread_join(e->thread, NULL); e->thread_started = 0;
    }
    if (e->initialized) { pthread_cond_destroy(&e->changed); pthread_mutex_destroy(&e->mutex); e->initialized = 0; }
    if (e->store_fd >= 0) { close(e->store_fd); e->store_fd = -1; }
    free(e->samples); e->samples = NULL;
}
static int equipment_close(lua_State *L) {
    struct equipment *e = luaL_checkudata(L, 1, EQUIPMENT_TYPE); shutdown_equipment(e); return 0;
}
static void config_text(lua_State *L, const char *key, char *target, size_t size, const char *fallback) {
    lua_getfield(L, 1, key); size_t n;
    const char *text = luaL_optlstring(L, -1, fallback, &n);
    if (n >= size || memchr(text, '\0', n)) luaL_error(L, "equipment %s is too long or contains NUL", key);
    memcpy(target, text, n + 1); lua_pop(L, 1);
}
static double config_number(lua_State *L, const char *key, double fallback, double maximum) {
    lua_getfield(L, 1, key); double value = luaL_optnumber(L, -1, fallback); lua_pop(L, 1);
    if (!isfinite(value) || value < 0 || value > maximum) luaL_error(L, "equipment %s is outside its supported range", key);
    return value;
}
static int prepare_store(lua_State *L, struct equipment *e, const char *path) {
    if (!*path) return 0;
    if (*path == '/' || strchr(path, '\\')) return EINVAL;
    char copy[PATH_BYTES]; strcpy(copy, path);
    for (const char *part = path; *part;) {
        const char *end = strchr(part, '/'); size_t size = end ? (size_t)(end - part) : strlen(part);
        if (!size || (size == 1 && part[0] == '.') || (size == 2 && part[0] == '.' && part[1] == '.') || (end && !end[1])) return EINVAL;
        part = end ? end + 1 : part + size;
    }
    lua_getfield(L, 1, "root");
    int fd = host_fs_dup_root(L, -1); lua_pop(L, 1);
    char *part = copy, *end;
    while ((end = strchr(part, '/')) != NULL) {
        *end = '\0';
        if (mkdirat(fd, part, 0700) && errno != EEXIST) { int code = errno; close(fd); return code; }
        int child = openat(fd, part, DIR_FLAGS); int code = errno; close(fd);
        if (child < 0) return code;
        fd = child; part = end + 1;
    }
    struct stat st;
    if (fstat(fd, &st)) { int code = errno; close(fd); return code; }
    if ((st.st_mode & 0077) || strlen(part) >= sizeof e->store_name) { close(fd); return EPERM; }
    strcpy(e->store_name, part); e->store_fd = fd; return 0;
}
static int equipment_open(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    struct equipment *e = lua_newuserdatauv(L, sizeof *e, 0); memset(e, 0, sizeof *e); e->store_fd = -1;
    luaL_setmetatable(L, EQUIPMENT_TYPE);
    e->interval = config_number(L, "intervalSeconds", 0, 86400 * 365);
    double capacity = config_number(L, "history", 1000, MAX_HISTORY);
    if (capacity < 1 || floor(capacity) != capacity) return luaL_error(L, "equipment history must be an integer from 1 to 10000");
    e->capacity = (int)capacity;
    if (e->interval > 0 && e->interval < 0.001) return luaL_error(L, "equipment interval must be at least one millisecond");
    e->temperature_limit = config_number(L, "temperatureCelsius", 0, 1e9);
    e->load_limit = config_number(L, "load", 0, 1e9);
    e->memory_limit = config_number(L, "memoryUsedPercent", 0, 100);
    config_text(L, "proc", e->proc, sizeof e->proc, ""); config_text(L, "sys", e->sys, sizeof e->sys, "");
    config_text(L, "syslog", e->syslog, sizeof e->syslog, "/var/log/messages");
    config_text(L, "units", e->units, sizeof e->units, "");
    char store[PATH_BYTES]; config_text(L, "store", store, sizeof store, "");
    if (e->interval) {
        e->samples = calloc((size_t)e->capacity, sizeof(struct sample));
        if (!e->samples) return luaL_error(L, "equipment history allocation failed");
    }
    int code = pthread_mutex_init(&e->mutex, NULL);
    if (code) return luaL_error(L, "initialize equipment mutex: %s", strerror(code));
    pthread_condattr_t condition; code = pthread_condattr_init(&condition);
    if (!code) {
#ifndef __APPLE__
        code = pthread_condattr_setclock(&condition, CLOCK_MONOTONIC);
#endif
        if (!code) code = pthread_cond_init(&e->changed, &condition);
        pthread_condattr_destroy(&condition);
    }
    if (code) { pthread_mutex_destroy(&e->mutex); return luaL_error(L, "initialize equipment condition: %s", strerror(code)); }
    e->initialized = 1;
    if (!e->interval) return 1;
    code = prepare_store(L, e, store);
    if (!code && e->store_fd >= 0) code = restore(e);
    if (code) { storage_error(e, "restore collection history", code); e->stopped = 1; return 1; }
    collect(e);
    pthread_attr_t attr; code = pthread_attr_init(&attr);
    if (!code) {
        /* Small explicit stack replaces multi-megabyte platform defaults. */
        size_t stack = 128 * 1024;
#ifdef PTHREAD_STACK_MIN
        if (stack < PTHREAD_STACK_MIN) stack = PTHREAD_STACK_MIN;
#endif
        code = pthread_attr_setstacksize(&attr, stack);
        if (!code) code = pthread_create(&e->thread, &attr, worker, e);
        pthread_attr_destroy(&attr);
    }
    if (code) return luaL_error(L, "start equipment collector: %s", strerror(code));
    e->thread_started = 1; return 1;
}
int luaopen_asenta_equipment(lua_State *L) {
    static const luaL_Reg methods[] = {
        {"state", equipment_state}, {"history", equipment_history}, {"sample", equipment_sample},
        {"alerts", equipment_alerts}, {"journal", equipment_journal}, {"close", equipment_close}, {NULL, NULL}
    };
    luaL_newmetatable(L, EQUIPMENT_TYPE); lua_pushvalue(L, -1); lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, methods, 0); lua_pushcfunction(L, equipment_close); lua_setfield(L, -2, "__gc"); lua_pop(L, 1);
    lua_newtable(L); lua_pushcfunction(L, equipment_open); lua_setfield(L, -2, "open");
    integer_field(L, "sampleBytes", sizeof(struct sample));
    return 1;
}
