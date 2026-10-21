#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#define _NETBSD_SOURCE
#include "host.h"
#include <lauxlib.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#ifdef __NetBSD__
#include <bluetooth.h>
#include <netbt/rfcomm.h>
#endif

#define LINK_TYPE "asenta.obd.link"
#define RESPONSE_LIMIT 16384

struct obd_link {
    int fd;
    int64_t deadline;
    char response[RESPONSE_LIMIT + 1];
    unsigned char bytes[RESPONSE_LIMIT / 2];
};

static int64_t obd_milliseconds(lua_State *L) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now))
        luaL_error(L, "obd_clock_failed: %s", strerror(errno));
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int obd_close(lua_State *L) {
    struct obd_link *link = luaL_checkudata(L, 1, LINK_TYPE);
    if (link->fd >= 0) { close(link->fd); link->fd = -1; }
    return 0;
}

static void io_error(lua_State *L) {
    luaL_error(L, "obd_rfcomm_connection_closed: %s", strerror(errno));
}

static void wait_fd(lua_State *L, int fd, short events, int64_t deadline) {
    for (;;) {
        int64_t remaining = deadline - obd_milliseconds(L);
        if (remaining <= 0) luaL_error(L, "obd_adapter_response_timeout");
        struct pollfd descriptor = {fd, events, 0};
        int ready = poll(&descriptor, 1, (int)remaining);
        if (ready < 0) { if (errno == EINTR) continue; io_error(L); }
        if (!ready) continue;
        /* A peer may close after its final response; consume those bytes. */
        if (descriptor.revents & events) return;
        luaL_error(L, "obd_rfcomm_connection_closed");
    }
}

static void nonblocking(lua_State *L, int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ||
        fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) io_error(L);
#ifdef SO_NOSIGPIPE
    int yes = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes) < 0) io_error(L);
#endif
}

static void connect_link(lua_State *L, struct obd_link *link,
                         const char *address, int channel) {
#ifdef __NetBSD__
    if (geteuid() == 0) luaL_error(L, "obd_requires_unprivileged_user");
    struct sockaddr_bt local = {0}, remote = {0};
    local.bt_len = remote.bt_len = sizeof local;
    local.bt_family = remote.bt_family = AF_BLUETOOTH;
    remote.bt_channel = (uint8_t)channel;
    if (!bt_aton(address, &remote.bt_bdaddr)) luaL_error(L, "obd_invalid_bluetooth_target");
    if (!bt_devaddr("btuart0", &local.bt_bdaddr)) io_error(L);
    link->fd = socket(AF_BLUETOOTH, SOCK_STREAM, BTPROTO_RFCOMM);
    if (link->fd < 0) io_error(L);
    nonblocking(L, link->fd);
    int mode = RFCOMM_LM_ENCRYPT;
    if (setsockopt(link->fd, BTPROTO_RFCOMM, SO_RFCOMM_LM, &mode, sizeof mode) < 0 ||
        bind(link->fd, (struct sockaddr *)&local, sizeof local) < 0) io_error(L);
    int64_t deadline = obd_milliseconds(L) + 10000;
    if (connect(link->fd, (struct sockaddr *)&remote, sizeof remote) < 0) {
        if (errno != EINPROGRESS) io_error(L);
        wait_fd(L, link->fd, POLLOUT, deadline);
        int error = 0;
        socklen_t size = sizeof error;
        if (getsockopt(link->fd, SOL_SOCKET, SO_ERROR, &error, &size) < 0) io_error(L);
        if (error) { errno = error; io_error(L); }
    }
#else
    (void)link; (void)address; (void)channel;
    luaL_error(L, "obd_rfcomm_requires_netbsd");
#endif
}

/* This is the complete command vocabulary, including adapter initialization.
 * No caller can supply arbitrary ELM or vehicle commands. */
static const char *const allowed_commands[] = {
    "ATZ", "ATE0", "ATL0", "ATS1", "ATH0", "ATSP0", "ATI", "ATRV", "ATDP",
    "0100", "0101", "0104", "0105", "010C", "010D", "010F", "0111", "011F",
    "0121", "012F", "0131", "0142", "03", "07", "0902"
};

static const char *command(lua_State *L, struct obd_link *link, const char *value, int wait) {
    size_t index;
    for (index = 0; index < sizeof allowed_commands / sizeof *allowed_commands; ++index)
        if (!strcmp(value, allowed_commands[index])) break;
    if (index == sizeof allowed_commands / sizeof *allowed_commands)
        luaL_error(L, "obd_command_not_read_only");
    int64_t deadline = obd_milliseconds(L) + (wait + 8) * 1000;
    if (deadline > link->deadline) deadline = link->deadline;
    size_t discarded = 0;
    for (;;) {
        char drain[256];
        ssize_t count = recv(link->fd, drain, sizeof drain, 0);
        if (count > 0) {
            discarded += (size_t)count;
            if (discarded > RESPONSE_LIMIT) luaL_error(L, "obd_response_too_long");
        } else if (!count) luaL_error(L, "obd_rfcomm_connection_closed");
        else if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        else if (errno != EINTR) io_error(L);
        if (obd_milliseconds(L) >= deadline) luaL_error(L, "obd_adapter_response_timeout");
    }
    char request[8];
    size_t length = (size_t)snprintf(request, sizeof request, "%s\r", value), sent = 0;
    while (sent < length) {
        wait_fd(L, link->fd, POLLOUT, deadline);
        ssize_t count = send(link->fd, request + sent, length - sent,
#ifdef MSG_NOSIGNAL
                             MSG_NOSIGNAL
#else
                             0
#endif
        );
        if (count > 0) sent += (size_t)count;
        else if (count == 0) luaL_error(L, "obd_rfcomm_connection_closed");
        else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) io_error(L);
    }
    size_t used = 0;
    for (;;) {
        wait_fd(L, link->fd, POLLIN, deadline);
        char chunk[256];
        ssize_t count = recv(link->fd, chunk, sizeof chunk, 0);
        if (!count) luaL_error(L, "obd_rfcomm_connection_closed");
        if (count < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            io_error(L);
        }
        if ((size_t)count > RESPONSE_LIMIT - used) luaL_error(L, "obd_response_too_long");
        memcpy(link->response + used, chunk, (size_t)count);
        used += (size_t)count;
        if (!memchr(chunk, '>', (size_t)count)) continue;
        size_t end = 0;
        for (size_t i = 0; i < used; ++i) {
            unsigned char ch = (unsigned char)link->response[i];
            if (ch != '>') link->response[end++] = ch != 0 ? (char)ch : '?';
        }
        while (end && isspace((unsigned char)link->response[end - 1])) --end;
        size_t start = 0;
        while (start < end && isspace((unsigned char)link->response[start])) ++start;
        memmove(link->response, link->response + start, end - start);
        link->response[end - start] = 0;
        return link->response;
    }
}

static int hex_digit(unsigned char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
}

/* Preserve the previous first-matching-line decoder, including empty payloads.
 * A missing or malformed response is not evidence that a vehicle has no DTCs. */
static int payload(struct obd_link *link, const char *key) {
    char *response = link->response;
    for (char *p = response; *p; ++p) *p = (char)toupper((unsigned char)*p);
    if (strstr(response, "NO DATA") || strstr(response, "UNABLE")) return -1;
    for (char *line = response; *line;) {
        char *end = line;
        while (*end && *end != '\r' && *end != '\n') ++end;
        char *next = *end ? end + 1 : end;
        size_t length = 0;
        for (char *p = line; p < end; ++p)
            if (hex_digit((unsigned char)*p) >= 0) line[length++] = *p;
        line[length] = 0;
        char *found = strstr(line, key);
        if (found) {
            found += strlen(key);
            size_t count = strlen(found) / 2;
            for (size_t i = 0; i < count; ++i)
                link->bytes[i] = (unsigned char)((hex_digit(found[i * 2]) << 4) | hex_digit(found[i * 2 + 1]));
            return (int)count;
        }
        line = next;
    }
    return -1;
}

static void push_null(lua_State *L) { lua_getfield(L, 3, "null"); }

static void push_codes(lua_State *L, struct obd_link *link, const char *mode) {
    int count = payload(link, mode);
    lua_newtable(L);
    lua_newtable(L); lua_pushliteral(L, "array"); lua_setfield(L, -2, "__jsontype");
    lua_setmetatable(L, -2);
    int at = 0;
    /* Odd-length CAN payloads carry a count before their two-byte codes. */
    for (int i = count > 0 ? count % 2 : 0; i + 1 < count; i += 2) {
        unsigned int first = link->bytes[i], second = link->bytes[i + 1];
        if (!first && !second) continue;
        char code[6];
        snprintf(code, sizeof code, "%c%u%X%02X", "PCBU"[first >> 6],
                 (first >> 4) & 3, first & 15, second);
        lua_pushstring(L, code); lua_rawseti(L, -2, ++at);
    }
}

static void push_vin(lua_State *L, struct obd_link *link) {
    size_t count = 0;
    const unsigned char *p = (const unsigned char *)link->response;
    while (*p) {
        if (hex_digit(*p) < 0) { ++p; continue; }
        const unsigned char *start = p;
        while (*p && hex_digit(*p) >= 0) ++p;
        if (p - start == 2) link->bytes[count++] = (unsigned char)((hex_digit(start[0]) << 4) | hex_digit(start[1]));
    }
    for (size_t i = 0; i + 2 < count; ++i) {
        if (link->bytes[i] != 0x49 || link->bytes[i + 1] != 0x02) continue;
        char vin[18] = {0};
        size_t length = 0;
        for (size_t j = i + 3; j < count; ++j) {
            unsigned char byte = link->bytes[j];
            if (!byte || !strchr("ABCDEFGHJKLMNPRSTUVWXYZ0123456789", byte)) continue;
            if (length < 17) vin[length++] = (char)byte;
            else { memmove(vin, vin + 1, 16); vin[16] = (char)byte; }
        }
        if (length == 17) { lua_pushstring(L, vin); return; }
        break;
    }
    push_null(L);
}

struct measurement { const char *query, *name; int count, convert; };
static const struct measurement measurements[] = {
    {"010C", "Engine speed, rpm", 2, 1},
    {"010D", "Speed, km/h", 1, 0},
    {"0105", "Coolant temperature, C", 1, 2},
    {"010F", "Intake air temperature, C", 1, 2},
    {"0104", "Engine load, percent", 1, 3},
    {"0111", "Throttle position, percent", 1, 3},
    {"012F", "Fuel level, percent", 1, 3},
    {"0142", "ECU voltage, V", 2, 4},
    {"011F", "Time since start, s", 2, 0},
    {"0121", "Distance with Check Engine, km", 2, 0},
    {"0131", "Distance since DTC reset, km", 2, 0}
};

static void string_field(lua_State *L, const char *key, const char *value) {
    lua_pushstring(L, value); lua_setfield(L, -2, key);
}

static void response_field(lua_State *L, const char *key, const char *response) {
    luaL_Buffer buffer;
    luaL_buffinit(L, &buffer);
    for (const unsigned char *p = (const unsigned char *)response; *p; ++p) {
        if (*p < 128) luaL_addchar(&buffer, (char)*p);
        else luaL_addlstring(&buffer, "\xef\xbf\xbd", 3);
    }
    luaL_pushresult(&buffer);
    lua_setfield(L, -2, key);
}

static void result_base(lua_State *L, const char *address) {
    time_t now = time(NULL);
    struct tm calendar;
    char timestamp[32];
    if (!localtime_r(&now, &calendar) || !strftime(timestamp, sizeof timestamp, "%Y-%m-%d %H:%M", &calendar))
        luaL_error(L, "obd_clock_failed");
    lua_newtable(L);
    string_field(L, "time", timestamp);
    string_field(L, "adapter_addr", address);
    lua_newtable(L);
    lua_newtable(L); lua_pushliteral(L, "object"); lua_setfield(L, -2, "__jsontype");
    lua_setmetatable(L, -2); lua_setfield(L, -2, "values");
}

static int collect(lua_State *L) {
    struct obd_link *link = luaL_checkudata(L, 1, LINK_TYPE);
    lua_getfield(L, 2, "address"); const char *address = lua_tostring(L, -1);
    lua_getfield(L, 2, "channel"); int channel = (int)lua_tointeger(L, -1);
    lua_settop(L, 3);
    if (link->fd < 0) connect_link(L, link, address, channel);
    nonblocking(L, link->fd);
    result_base(L, address);
    int result = lua_gettop(L);
    command(L, link, "ATZ", 2);
    const char *setup[] = {"ATE0", "ATL0", "ATS1", "ATH0", "ATSP0"};
    for (size_t i = 0; i < sizeof setup / sizeof *setup; ++i) command(L, link, setup[i], 1);
    response_field(L, "adapter", command(L, link, "ATI", 1));
    response_field(L, "battery_v", command(L, link, "ATRV", 1));
    command(L, link, "0100", 6);
    int initial = payload(link, "4100");
    response_field(L, "protocol", command(L, link, "ATDP", 1));
    if (initial < 0) return luaL_error(L, "obd_vehicle_did_not_answer");
    lua_getfield(L, result, "values"); int values = lua_gettop(L);
    lua_getfield(L, 2, "labels"); int labels = lua_gettop(L);
    for (size_t i = 0; i < sizeof measurements / sizeof *measurements; ++i) {
        const struct measurement *m = &measurements[i];
        command(L, link, m->query, 1);
        char key[] = "4100"; memcpy(key + 2, m->query + 2, 2);
        int count = payload(link, key);
        if (lua_istable(L, labels)) lua_getfield(L, labels, m->name); else lua_pushnil(L);
        if (!lua_isstring(L, -1)) { lua_pop(L, 1); lua_pushstring(L, m->name); }
        if (count < m->count) push_null(L);
        else {
            int raw = m->count == 2 ? link->bytes[0] * 256 + link->bytes[1] : link->bytes[0];
            double number = raw;
            if (m->convert == 1) number = raw / 4.0;
            else if (m->convert == 2) number = raw - 40;
            else if (m->convert == 3) number = ((raw * 1000 + 127) / 255) / 10.0;
            else if (m->convert == 4) number = raw / 1000.0;
            lua_pushnumber(L, number);
        }
        lua_settable(L, values);
    }
    lua_settop(L, result);
    command(L, link, "0101", 1);
    if (payload(link, "4101") > 0) {
        lua_pushboolean(L, link->bytes[0] & 0x80); lua_setfield(L, result, "check_engine");
        lua_pushinteger(L, link->bytes[0] & 0x7f); lua_setfield(L, result, "dtc_count");
    }
    command(L, link, "03", 4); push_codes(L, link, "43"); lua_setfield(L, result, "dtc_stored");
    command(L, link, "07", 4); push_codes(L, link, "47"); lua_setfield(L, result, "dtc_pending");
    command(L, link, "0902", 6); push_vin(L, link); lua_setfield(L, result, "vin");
    return 1;
}

static void require_module(lua_State *L, const char *name) {
    lua_getglobal(L, "require"); lua_pushstring(L, name); lua_call(L, 1, 1);
}

/* Reuse the host's atomic, fsynced private file writer. Error snapshots contain
 * no partial successful readings, matching the former Python collect/update. */
static void save_snapshot(lua_State *L, int result, int json) {
    int top = lua_gettop(L);
    lua_getfield(L, 1, "snapshotPath");
    const char *path = lua_tostring(L, -1), *name;
    if (path) {
        const char *slash = strrchr(path, '/');
        name = slash ? slash + 1 : path;
        if (slash) lua_pushlstring(L, path, slash == path ? 1 : (size_t)(slash - path));
        else lua_pushliteral(L, ".");
    } else {
        const char *directory = getenv("VOICE_KB_LIVE");
        lua_pushstring(L, directory ? directory : "/srv/oxtorg-kb/v200/live");
        time_t now = time(NULL);
        struct tm calendar;
        char timestamp[64];
        if (!localtime_r(&now, &calendar) || !strftime(timestamp, sizeof timestamp, "obd-%Y-%m-%d_%H%M%S.json", &calendar))
            luaL_error(L, "obd_clock_failed");
        lua_pushstring(L, timestamp);
        name = lua_tostring(L, -1);
        lua_insert(L, -2);
    }
    int directory = lua_gettop(L);
    require_module(L, "asenta.fs"); lua_getfield(L, -1, "root");
    lua_pushvalue(L, directory); lua_pushboolean(L, 1); lua_call(L, 2, 2);
    if (lua_isnil(L, -2)) luaL_error(L, "obd_snapshot_failed: %s", lua_tostring(L, -1));
    lua_pop(L, 1); int root = lua_gettop(L); lua_toclose(L, root);
    lua_getfield(L, json, "encode"); lua_pushvalue(L, result); lua_call(L, 1, 1);
    lua_pushliteral(L, "\n"); lua_concat(L, 2); int body = lua_gettop(L);
    lua_getfield(L, root, "write"); lua_pushvalue(L, root);
    lua_pushstring(L, name); lua_pushvalue(L, body); lua_call(L, 3, 2);
    if (!lua_toboolean(L, -2)) luaL_error(L, "obd_snapshot_failed: %s", lua_tostring(L, -1));
    lua_closeslot(L, root); lua_settop(L, top);
}

/* The fd argument is private to the C test harness. Lua only gets read(). */
static int read_session(lua_State *L, int fd) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "address"); size_t size;
    const char *address = lua_tolstring(L, -1, &size);
    int valid = address && size == 17;
    for (size_t i = 0; valid && i < size; ++i)
        valid = i % 3 == 2 ? address[i] == ':' : hex_digit((unsigned char)address[i]) >= 0;
    lua_getfield(L, 1, "channel");
    lua_Integer channel = lua_tointeger(L, -1);
    if (!valid || !lua_isinteger(L, -1) || channel < 1 || channel > 30)
        return luaL_error(L, "obd_invalid_bluetooth_target");
    lua_getfield(L, 1, "snapshotPath");
    if (!lua_isnil(L, -1)) {
        size_t length;
        const char *path = luaL_checklstring(L, -1, &length);
        luaL_argcheck(L, length > 0 && !memchr(path, 0, length) && path[length - 1] != '/', 1, "invalid snapshotPath");
    }
    lua_settop(L, 1);
    require_module(L, "json"); int json = lua_gettop(L);
    struct obd_link *link = lua_newuserdatauv(L, sizeof *link, 0);
    link->fd = fd;
    luaL_setmetatable(L, LINK_TYPE); int owner = lua_gettop(L); lua_toclose(L, owner);
    link->deadline = obd_milliseconds(L) + 180000;
    lua_pushcfunction(L, collect); lua_pushvalue(L, owner);
    lua_pushvalue(L, 1); lua_pushvalue(L, json);
    int status = lua_pcall(L, 3, 1, 0);
    lua_closeslot(L, owner);
    if (status != LUA_OK) {
        const char *error = lua_tostring(L, -1);
        result_base(L, address);
        string_field(L, "error", error ? error : "obd_read_failed");
    }
    save_snapshot(L, lua_gettop(L), json);
    if (status != LUA_OK) { lua_pop(L, 1); return lua_error(L); }
    return 1;
}

static int read_obd(lua_State *L) { return read_session(L, -1); }

int luaopen_asenta_obd(lua_State *L) {
    luaL_newmetatable(L, LINK_TYPE);
    lua_pushcfunction(L, obd_close); lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, obd_close); lua_setfield(L, -2, "__close");
    lua_pop(L, 1);
    static const luaL_Reg module[] = {{"read", read_obd}, {NULL, NULL}};
    luaL_newlib(L, module);
    return 1;
}
