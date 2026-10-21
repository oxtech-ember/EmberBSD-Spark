#include "host.h"
#include <lauxlib.h>
#include <curl/curl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static CURL *connection;
static int active;
struct buffer { char *data; size_t used, capacity, limit; };
struct transfer {
    lua_State *L;
    struct buffer body, headers;
    int consume, stopped, callback_error, reader, upload_done;
    size_t streamed, upload_size, uploaded;
};

static void upload_error(struct transfer *t, const char *message) {
    lua_pushstring(t->L, message);
    t->callback_error = luaL_ref(t->L, LUA_REGISTRYINDEX);
}

/* A successful nonempty part stays on the Lua stack until copied to curl.
 * nil is EOF; empty strings would leave an upload spinning without progress. */
static int upload_part(struct transfer *t, size_t wanted, size_t *length) {
    lua_State *L = t->L;
    lua_pushvalue(L, t->reader);
    lua_pushinteger(L, (lua_Integer)wanted);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        t->callback_error = luaL_ref(L, LUA_REGISTRYINDEX);
        return -1;
    }
    if (lua_isnil(L, -1)) { lua_pop(L, 1); return 0; }
    if (lua_type(L, -1) != LUA_TSTRING) {
        lua_pop(L, 1);
        upload_error(t, "bodyReader must return a string or nil at EOF");
        return -1;
    }
    lua_tolstring(L, -1, length);
    if (*length == 0 || *length > wanted) {
        lua_pop(L, 1);
        upload_error(t, "bodyReader returned an empty or oversized chunk");
        return -1;
    }
    return 1;
}

static size_t send_body(char *data, size_t size, size_t count, void *context) {
    struct transfer *t = context;
    if (t->upload_done) return 0;
    if (size && count > SIZE_MAX / size) {
        upload_error(t, "bodyReader buffer size overflow");
        return CURL_READFUNC_ABORT;
    }
    size_t capacity = size * count;
    if (!capacity) return 0;
    size_t remaining = t->upload_size - t->uploaded;
    size_t wanted = capacity < 4096 ? capacity : 4096;
    if (wanted > remaining) wanted = remaining;
    size_t length = 0;
    int part = upload_part(t, wanted ? wanted : 1, &length);
    if (part < 0) return CURL_READFUNC_ABORT;
    if (!remaining) {
        if (!part) { t->upload_done = 1; return 0; }
        lua_pop(t->L, 1);
        upload_error(t, "bodyReader exceeds bodyBytes");
        return CURL_READFUNC_ABORT;
    }
    if (!part) {
        upload_error(t, "bodyReader ended before bodyBytes");
        return CURL_READFUNC_ABORT;
    }
    /* curl may never call us after its declared length. Check EOF before
     * delivering the last part, so extra bytes cannot be silently discarded. */
    if (length == remaining) {
        size_t extra = 0;
        int tail = upload_part(t, 1, &extra);
        if (tail) {
            if (tail > 0) {
                lua_pop(t->L, 1);
                upload_error(t, "bodyReader exceeds bodyBytes");
            }
            lua_pop(t->L, 1);
            return CURL_READFUNC_ABORT;
        }
        t->upload_done = 1;
    }
    memcpy(data, lua_tostring(t->L, -1), length);
    lua_pop(t->L, 1);
    t->uploaded += length;
    return length;
}

static size_t collect(char *data, size_t size, size_t count, void *context) {
    struct buffer *b = context;
    if (size && count > SIZE_MAX / size) return 0;
    size_t n = size * count;
    if (n > b->limit - b->used) return 0;
    size_t needed = b->used + n;
    if (needed > b->capacity) {
        size_t capacity = b->capacity ? b->capacity * 2 : 4096;
        if (capacity < needed) capacity = needed;
        if (capacity > b->limit) capacity = b->limit;
        char *next = realloc(b->data, capacity);
        if (!next) return 0;
        b->data = next; b->capacity = capacity;
    }
    if (n) memcpy(b->data + b->used, data, n);
    b->used += n;
    return n;
}

static size_t receive(char *data, size_t size, size_t count, void *context) {
    struct transfer *t = context;
    long status = 0;
    curl_easy_getinfo(connection, CURLINFO_RESPONSE_CODE, &status);
    if (!t->consume || status < 200 || status >= 300)
        return collect(data, size, count, &t->body);
    if (size && count > SIZE_MAX / size) return 0;
    size_t n = size * count;
    if (n > t->body.limit - t->streamed) return 0;
    t->streamed += n;
    lua_State *L = t->L;
    lua_pushvalue(L, t->consume);
    lua_pushlstring(L, data, n);
    lua_pushinteger(L, status);
    if (lua_pcall(L, 2, 1, 0) != LUA_OK) {
        t->callback_error = luaL_ref(L, LUA_REGISTRYINDEX);
        return 0;
    }
    t->stopped = lua_isboolean(L, -1) && !lua_toboolean(L, -1);
    lua_pop(L, 1);
    return t->stopped ? 0 : n;
}

static const char *field(lua_State *L, const char *name, const char *fallback) {
    lua_getfield(L, 1, name);
    return lua_isnil(L, -1) ? fallback : luaL_checkstring(L, -1);
}

static lua_Integer number(lua_State *L, const char *name, lua_Integer fallback) {
    lua_getfield(L, 1, name);
    lua_Integer value = luaL_optinteger(L, -1, fallback);
    lua_pop(L, 1);
    luaL_argcheck(L, value > 0, 1, "transport limits must be positive");
    return value;
}

static int append_header(struct curl_slist **headers, const char *value) {
    struct curl_slist *next = curl_slist_append(*headers, value);
    if (!next) return 0;
    *headers = next;
    return 1;
}

int host_http(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    luaL_argcheck(L, !active, 1, "HTTP callback cannot start another request");
    lua_Integer limit = number(L, "maxBytes", 131072);
    luaL_argcheck(L, (lua_Integer)(size_t)limit == limit, 1, "maxBytes exceeds the addressable size");
    lua_Integer timeout = number(L, "timeoutMs", 30000);
    const char *url = field(L, "url", NULL);
    const char *method = field(L, "method", "GET");
    const char *ca = field(L, "caFile", NULL);
    const char *token = field(L, "token", "");
    lua_getfield(L, 1, "body");
    size_t length = 0;
    const char *body = lua_isnil(L, -1) ? NULL : luaL_checklstring(L, -1, &length);
    lua_getfield(L, 1, "bodyReader");
    int reader = lua_isnil(L, -1) ? 0 : lua_gettop(L);
    if (reader) {
        luaL_checktype(L, reader, LUA_TFUNCTION);
        luaL_argcheck(L, !body, 1, "body and bodyReader are mutually exclusive");
        lua_getfield(L, 1, "bodyBytes");
        lua_Integer bytes = luaL_checkinteger(L, -1);
        luaL_argcheck(L, bytes >= 0 && bytes <= limit, 1, "bodyBytes must be within maxBytes");
        length = (size_t)bytes;
        lua_pop(L, 1);
    }
    luaL_argcheck(L, url != NULL, 1, "url is required");
    luaL_argcheck(L, length <= (size_t)limit, 1, "request exceeds maxBytes");
    luaL_argcheck(L, !strchr(token, '\r') && !strchr(token, '\n'), 1, "invalid bearer token");
    lua_getfield(L, 1, "consume");
    int consume = lua_isnil(L, -1) ? 0 : lua_gettop(L);
    if (consume) luaL_checktype(L, consume, LUA_TFUNCTION);
    lua_getfield(L, 1, "headers");
    int custom = lua_gettop(L), content_type = 0, authorization = 0;
    if (!lua_isnil(L, custom)) {
        luaL_checktype(L, custom, LUA_TTABLE);
        lua_pushnil(L);
        while (lua_next(L, custom)) {
            luaL_checktype(L, -2, LUA_TSTRING);
            luaL_checktype(L, -1, LUA_TSTRING);
            size_t kn, vn;
            const char *k = lua_tolstring(L, -2, &kn), *v = lua_tolstring(L, -1, &vn);
            luaL_argcheck(L, kn && !memchr(k, '\0', kn) && !memchr(v, '\0', vn) &&
                strcspn(k, "\r\n:") == kn && strcspn(v, "\r\n") == vn, 1, "invalid HTTP header");
            content_type |= strcasecmp(k, "Content-Type") == 0;
            authorization |= strcasecmp(k, "Authorization") == 0;
            lua_pop(L, 1);
        }
    }
    if (!connection) connection = curl_easy_init();
    if (!connection) return luaL_error(L, "cannot create HTTP transport");
    curl_easy_reset(connection); /* Keeps the connection and TLS session cache. */
    struct transfer transfer = {.L=L, .body={.limit=(size_t)limit},
        .headers={.limit=65536}, .consume=consume, .callback_error=LUA_NOREF,
        .reader=reader, .upload_size=length};
    struct curl_slist *headers = NULL;
    if (!content_type && !append_header(&headers, "Content-Type: application/json")) goto allocation;
    if (*token && !authorization) {
        lua_pushfstring(L, "Authorization: Bearer %s", token);
        int ok = append_header(&headers, lua_tostring(L, -1));
        lua_pop(L, 1);
        if (!ok) goto allocation;
    }
    if (!lua_isnil(L, custom)) {
        lua_pushnil(L);
        while (lua_next(L, custom)) {
            lua_pushfstring(L, "%s: %s", lua_tostring(L, -2), lua_tostring(L, -1));
            int ok = append_header(&headers, lua_tostring(L, -1));
            lua_pop(L, 2);
            if (!ok) goto allocation;
        }
    }
    char error[CURL_ERROR_SIZE] = {0};
    curl_easy_setopt(connection, CURLOPT_URL, url);
    curl_easy_setopt(connection, CURLOPT_CUSTOMREQUEST, method);
    curl_easy_setopt(connection, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(connection, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(connection, CURLOPT_UPLOAD_BUFFERSIZE, 16384L);
    curl_easy_setopt(connection, CURLOPT_TIMEOUT_MS, (long)timeout);
    curl_easy_setopt(connection, CURLOPT_CONNECTTIMEOUT_MS, (long)timeout);
    curl_easy_setopt(connection, CURLOPT_WRITEFUNCTION, receive);
    curl_easy_setopt(connection, CURLOPT_WRITEDATA, &transfer);
    curl_easy_setopt(connection, CURLOPT_HEADERFUNCTION, collect);
    curl_easy_setopt(connection, CURLOPT_HEADERDATA, &transfer.headers);
    curl_easy_setopt(connection, CURLOPT_ERRORBUFFER, error);
    curl_easy_setopt(connection, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(connection, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(connection, CURLOPT_PROTOCOLS_STR, "http,https");
    if (ca && *ca) curl_easy_setopt(connection, CURLOPT_CAINFO, ca);
    if (reader) {
        curl_easy_setopt(connection, CURLOPT_POST, 1L);
        curl_easy_setopt(connection, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)length);
        curl_easy_setopt(connection, CURLOPT_READFUNCTION, send_body);
        curl_easy_setopt(connection, CURLOPT_READDATA, &transfer);
    } else if (body) {
        curl_easy_setopt(connection, CURLOPT_POSTFIELDS, body);
        curl_easy_setopt(connection, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)length);
    }
    active = 1;
    char unused;
    CURLcode result = reader && !length && send_body(&unused, 1, 1, &transfer) == CURL_READFUNC_ABORT
        ? CURLE_ABORTED_BY_CALLBACK : curl_easy_perform(connection);
    active = 0;
    long status = 0;
    curl_easy_getinfo(connection, CURLINFO_RESPONSE_CODE, &status);
    if (reader && result == CURLE_OK && status >= 200 && status < 300 && !transfer.upload_done) {
        upload_error(&transfer, "request body was not fully uploaded");
        result = CURLE_READ_ERROR;
    }
    curl_slist_free_all(headers);
    if (result == CURLE_OK || (result == CURLE_WRITE_ERROR && transfer.stopped)) {
        lua_pushinteger(L, status);
        lua_pushlstring(L, transfer.body.data ? transfer.body.data : "", transfer.body.used);
    } else {
        lua_pushnil(L);
        if (transfer.callback_error != LUA_NOREF) {
            lua_rawgeti(L, LUA_REGISTRYINDEX, transfer.callback_error);
            luaL_unref(L, LUA_REGISTRYINDEX, transfer.callback_error);
        } else lua_pushstring(L, result == CURLE_WRITE_ERROR ? "response exceeds maxBytes or allocation failed" : error);
    }
    lua_pushlstring(L, transfer.headers.data ? transfer.headers.data : "", transfer.headers.used);
    free(transfer.body.data);
    free(transfer.headers.data);
    return 3;
allocation:
    curl_slist_free_all(headers);
    return luaL_error(L, "cannot allocate HTTP headers");
}

void host_http_close(void) {
    if (connection) curl_easy_cleanup(connection);
    connection = NULL;
}
