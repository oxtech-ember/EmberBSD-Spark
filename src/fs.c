#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#define _NETBSD_SOURCE
#include "host.h"
#include <lauxlib.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#ifdef __NetBSD__
#include <sha2.h>
#elif defined(__APPLE__)
#include <CommonCrypto/CommonDigest.h>
#else
#include <openssl/evp.h>
#include <openssl/rand.h>
#endif
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifdef __APPLE__
/* CommonCrypto and arc4random are part of macOS, so the native client does
 * not acquire a separate OpenSSL installation for hashes and temp names. */
typedef CC_SHA256_CTX SHA256_CTX;
#define SHA256_Init CC_SHA256_Init
#define SHA256_Final CC_SHA256_Final
static int SHA256_Update(SHA256_CTX *ctx, const void *bytes, size_t length) {
    const unsigned char *at = bytes;
    while (length) {
        CC_LONG count = length > UINT32_MAX ? UINT32_MAX : (CC_LONG)length;
        if (!CC_SHA256_Update(ctx, at, count)) return 0;
        at += count;
        length -= count;
    }
    return 1;
}
#endif

/* This is confined storage for trusted Lua application code, not a process
 * sandbox. The application chooses a trusted root using normal OS paths;
 * every descendant is walked through openat without following links.
 * stat/list describe a final symlink; remove/rename act on that entry itself.
 * Content operations accept regular files only, including after opening them.
 * Invalid arguments raise Lua errors; OS failures return nil and a detail. */
#define ROOT_TYPE "asenta.fs.root"
#define LOCK_TYPE "asenta.fs.lock"
#define DIR_FLAGS (O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

struct handle { int fd; };

/* Native workers own this descriptor independently of Lua object lifetimes. */
int host_fs_dup_root(lua_State *L, int index) {
    struct handle *h = luaL_checkudata(L, index, ROOT_TYPE);
    luaL_argcheck(L, h->fd >= 0, index, "filesystem root is closed");
    int fd = openat(h->fd, ".", DIR_FLAGS);
    if (fd < 0) luaL_error(L, "duplicate filesystem root: %s", strerror(errno));
    return fd;
}

static int failure(lua_State *L, const char *operation, int code) {
    lua_pushnil(L);
    lua_pushfstring(L, "%s: %s", operation, strerror(code));
    return 2;
}

static int detail(lua_State *L, const char *message) {
    lua_pushnil(L); lua_pushstring(L, message); return 2;
}

static int success(lua_State *L) { lua_pushboolean(L, 1); return 1; }

static struct handle *root_handle(lua_State *L) {
    struct handle *h = luaL_checkudata(L, 1, ROOT_TYPE);
    luaL_argcheck(L, h->fd >= 0, 1, "filesystem root is closed");
    return h;
}

/* Only list permits the empty relative path, meaning the already open root.
 * No Unicode, extension or size policy belongs here; worktree owns those. */
static const char *relative(lua_State *L, int index, int empty) {
    size_t length;
    const char *name = empty ? luaL_optlstring(L, index, "", &length)
                             : luaL_checklstring(L, index, &length);
    luaL_argcheck(L, (empty || length != 0) && name[0] != '/' &&
                  memchr(name, '\0', length) == NULL && strchr(name, '\\') == NULL,
                  index, "expected a relative path without NUL or backslashes");
    for (const char *part = name; *part;) {
        const char *end = strchr(part, '/');
        size_t size = end ? (size_t)(end - part) : strlen(part);
        luaL_argcheck(L, size != 0 && !(size == 1 && part[0] == '.') &&
                      !(size == 2 && part[0] == '.' && part[1] == '.') &&
                      !(end && end[1] == '\0'), index,
                      "empty, dot and dotdot path components are not allowed");
        part = end ? end + 1 : part + size;
    }
    return name;
}

/* Returns a separately owned directory fd. openat(".") also sets CLOEXEC
 * atomically, so neither a root nor an intermediate fd reaches a child. */
static int walk_directory(int root, const char *name, int create, int flags) {
    int fd = openat(root, ".", DIR_FLAGS);
    if (fd < 0 || !*name) return fd;
    char *path = strdup(name);
    if (!path) { int code = errno; close(fd); errno = code; return -1; }
    char *part = path;
    while (part) {
        char *next = strchr(part, '/');
        if (next) *next++ = '\0';
        if (!*part) { part = next; continue; }
        int child = openat(fd, part, flags);
        if (child < 0 && errno == ENOENT && create) {
            if (mkdirat(fd, part, 0700) == 0) {
                if (fsync(fd) < 0) goto failed;
            } else if (errno != EEXIST) goto failed;
            child = openat(fd, part, flags);
        }
        if (child < 0) goto failed;
        close(fd); fd = child; part = next;
    }
    free(path);
    return fd;
failed: {
        int code = errno;
        free(path); close(fd); errno = code;
        return -1;
    }
}

static int directory_at(int root, const char *name, int create) {
    return walk_directory(root, name, create, DIR_FLAGS);
}

static int parent_at(int root, const char *name, int create, const char **base) {
    const char *slash = strrchr(name, '/');
    *base = slash ? slash + 1 : name;
    if (!slash) return directory_at(root, "", 0);
    size_t length = (size_t)(slash - name);
    char *parent = malloc(length + 1);
    if (!parent) return -1;
    memcpy(parent, name, length); parent[length] = '\0';
    int fd = directory_at(root, parent, create);
    int code = errno;
    free(parent); errno = code;
    return fd;
}

static int close_handle(lua_State *L) {
    struct handle *h = luaL_testudata(L, 1, ROOT_TYPE);
    if (!h) h = luaL_testudata(L, 1, LOCK_TYPE);
    luaL_argcheck(L, h != NULL, 1, "expected a filesystem root or lock");
    if (h->fd >= 0) {
        int fd = h->fd;
        h->fd = -1;
        if (close(fd) < 0) return failure(L, "close", errno);
    }
    return success(L);
}

static struct handle *new_handle(lua_State *L, const char *type) {
    struct handle *h = lua_newuserdatauv(L, sizeof *h, 0);
    h->fd = -1;
    luaL_setmetatable(L, type);
    return h;
}

static int fs_root(lua_State *L) {
    size_t length;
    const char *given = luaL_checklstring(L, 1, &length);
    luaL_argcheck(L, lua_isnoneornil(L, 2) || lua_isboolean(L, 2), 2,
                  "create must be a boolean");
    int create = lua_toboolean(L, 2);
    luaL_argcheck(L, length != 0 && memchr(given, '\0', length) == NULL, 1,
                  "filesystem root must be a non-empty path without NUL");
    /* A trusted installation path can contain symlinks (for example /tmp
     * on macOS). Once opened, only this descriptor anchors content access. */
    int absolute = given[0] == '/';
    struct handle *h = new_handle(L, ROOT_TYPE);
    int start = open(absolute ? "/" : ".", DIR_FLAGS);
    if (start < 0) return failure(L, "open root", errno);
    h->fd = walk_directory(start, given + absolute, create, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    int code = errno;
    close(start);
    if (h->fd < 0) return failure(L, "open root", code);
    return 1;
}

static int fs_read(lua_State *L) {
    struct handle *h = root_handle(L);
    const char *name = relative(L, 2, 0), *base;
    lua_Integer bound = luaL_optinteger(L, 3, 131072);
    luaL_argcheck(L, bound >= 0 && (uintmax_t)bound < SIZE_MAX, 3,
                  "read limit must be a non-negative representable size");
    size_t limit = (size_t)bound;
    int parent = parent_at(h->fd, name, 0, &base);
    if (parent < 0) return failure(L, "read parent", errno);
    int fd = openat(parent, base, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    int code = errno;
    close(parent);
    if (fd < 0) return failure(L, "read", code);
    struct stat status;
    if (fstat(fd, &status) < 0) {
        code = errno; close(fd); return failure(L, "read stat", code);
    }
    if (!S_ISREG(status.st_mode)) {
        close(fd); return detail(L, "read requires a regular file");
    }
    if (status.st_size < 0 || (uintmax_t)status.st_size > limit) {
        close(fd); return detail(L, "file exceeds read limit");
    }
    size_t capacity = (size_t)status.st_size + 1, length = 0;
    char *body = malloc(capacity);
    if (!body) { code = errno; close(fd); return failure(L, "allocate read", code); }
    for (;;) {
        /* A concurrently growing file is bounded by the call's limit too. */
        if (length == capacity) {
            size_t next = capacity <= (limit + 1) / 2 ? capacity * 2 : limit + 1;
            char *grown = realloc(body, next);
            if (!grown) { code = errno; break; }
            body = grown; capacity = next;
        }
        ssize_t count = read(fd, body + length, capacity - length);
        if (count < 0) { if (errno == EINTR) continue; code = errno; break; }
        if (count == 0) { code = 0; break; }
        length += (size_t)count;
        if (length > limit) { code = EFBIG; break; }
    }
    if (close(fd) < 0 && code == 0) code = errno;
    if (code) {
        free(body);
        return code == EFBIG ? detail(L, "file exceeds read limit") : failure(L, "read", code);
    }
    lua_pushlstring(L, body, length);
    free(body);
    return 1;
}

static int fs_write(lua_State *L) {
    struct handle *h = root_handle(L);
    const char *name = relative(L, 2, 0), *base;
    size_t length;
    const char *body = luaL_checklstring(L, 3, &length);
    int parent = parent_at(h->fd, name, 1, &base);
    if (parent < 0) return failure(L, "write parent", errno);
    struct stat status;
    if (fstatat(parent, base, &status, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISREG(status.st_mode)) {
            close(parent); return detail(L, "write requires a regular file destination");
        }
    } else if (errno != ENOENT) {
        int code = errno; close(parent); return failure(L, "write stat", code);
    }
    unsigned char random[16];
    char temporary[sizeof ".asenta-" + sizeof random * 2];
#if defined(__NetBSD__) || defined(__APPLE__)
    arc4random_buf(random, sizeof random);
#else
    if (RAND_bytes(random, sizeof random) != 1) {
        close(parent); return detail(L, "cannot generate temporary file name");
    }
#endif
    memcpy(temporary, ".asenta-", 7);
    for (size_t i = 0; i < sizeof random; ++i)
        snprintf(temporary + 7 + i * 2, 3, "%02x", random[i]);
    int fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) { int code = errno; close(parent); return failure(L, "create temporary file", code); }
    int code = 0;
    if (fchmod(fd, 0600) < 0) code = errno;
    for (size_t written = 0; !code && written < length;) {
        ssize_t count = write(fd, body + written, length - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { code = count < 0 ? errno : EIO; break; }
        written += (size_t)count;
    }
    if (!code && fsync(fd) < 0) code = errno;
    if (close(fd) < 0 && !code) code = errno;
    if (!code && renameat(parent, temporary, parent, base) < 0) code = errno;
    if (code) {
        unlinkat(parent, temporary, 0); close(parent);
        return failure(L, "write", code);
    }
    /* Failures before rename preserve the previous bytes. After rename, an
     * fsync failure cannot roll the write back safely: report that ambiguity. */
    if (fsync(parent) < 0) {
        code = errno; close(parent);
        return failure(L, "write committed; directory sync failed", code);
    }
    close(parent);
    return success(L);
}

static int fs_mkdir(lua_State *L) {
    struct handle *h = root_handle(L);
    const char *name = relative(L, 2, 0);
    int fd = directory_at(h->fd, name, 1);
    if (fd < 0) return failure(L, "mkdir", errno);
    int code = fsync(fd) < 0 ? errno : 0;
    close(fd);
    return code ? failure(L, "mkdir sync", code) : success(L);
}

static void push_stat(lua_State *L, const struct stat *status) {
    const char *kind = S_ISREG(status->st_mode) ? "file" :
                       S_ISDIR(status->st_mode) ? "directory" :
                       S_ISLNK(status->st_mode) ? "symlink" : "other";
    lua_newtable(L);
    lua_pushstring(L, kind); lua_setfield(L, -2, "kind");
    lua_pushinteger(L, (lua_Integer)status->st_size); lua_setfield(L, -2, "size");
}

static int fs_stat(lua_State *L) {
    struct handle *h = root_handle(L);
    const char *name = relative(L, 2, 0), *base;
    int parent = parent_at(h->fd, name, 0, &base);
    if (parent < 0) {
        if (errno == ENOENT) { lua_pushnil(L); return 1; }
        return failure(L, "stat parent", errno);
    }
    struct stat status;
    int result = fstatat(parent, base, &status, AT_SYMLINK_NOFOLLOW), code = errno;
    close(parent);
    if (result < 0) {
        if (code == ENOENT) { lua_pushnil(L); return 1; }
        return failure(L, "stat", code);
    }
    push_stat(L, &status);
    return 1;
}

static int fs_list(lua_State *L) {
    struct handle *h = root_handle(L);
    const char *name = relative(L, 2, 1);
    int fd = directory_at(h->fd, name, 0);
    if (fd < 0) return failure(L, "list", errno);
    DIR *directory = fdopendir(fd);
    if (!directory) { int code = errno; close(fd); return failure(L, "list", code); }
    lua_newtable(L);
    lua_Integer index = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (!entry) {
            int code = errno;
            if (closedir(directory) < 0 && !code) code = errno;
            return code ? failure(L, "list", code) : 1;
        }
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        struct stat status;
        if (fstatat(fd, entry->d_name, &status, AT_SYMLINK_NOFOLLOW) < 0) {
            int code = errno; closedir(directory); return failure(L, "list stat", code);
        }
        push_stat(L, &status);
        lua_pushstring(L, entry->d_name); lua_setfield(L, -2, "name");
        lua_rawseti(L, -2, ++index);
    }
}

static int fs_remove(lua_State *L) {
    struct handle *h = root_handle(L);
    const char *name = relative(L, 2, 0), *base;
    int parent = parent_at(h->fd, name, 0, &base);
    if (parent < 0) return failure(L, "remove parent", errno);
    struct stat status;
    int code = 0;
    if (fstatat(parent, base, &status, AT_SYMLINK_NOFOLLOW) < 0) code = errno;
    if (!code && unlinkat(parent, base, S_ISDIR(status.st_mode) ? AT_REMOVEDIR : 0) < 0) code = errno;
    if (code) { close(parent); return failure(L, "remove", code); }
    code = fsync(parent) < 0 ? errno : 0;
    close(parent);
    return code ? failure(L, "remove committed; directory sync failed", code) : success(L);
}

static int fs_rename(lua_State *L) {
    struct handle *h = root_handle(L);
    const char *from = relative(L, 2, 0), *to = relative(L, 3, 0);
    const char *oldbase, *newbase;
    int oldparent = parent_at(h->fd, from, 0, &oldbase);
    if (oldparent < 0) return failure(L, "rename source parent", errno);
    int newparent = parent_at(h->fd, to, 0, &newbase);
    if (newparent < 0) { int code = errno; close(oldparent); return failure(L, "rename target parent", code); }
    int result = renameat(oldparent, oldbase, newparent, newbase), code = errno;
    if (result == 0) {
        code = fsync(newparent) < 0 ? errno : 0;
        if (fsync(oldparent) < 0 && !code) code = errno;
    }
    close(oldparent); close(newparent);
    if (code) return failure(L, result < 0 ? "rename" : "rename committed; directory sync failed", code);
    return success(L);
}

static int fs_lock(lua_State *L) {
    struct handle *h = root_handle(L);
    const char *name = relative(L, 2, 0), *base;
    struct handle *lock = new_handle(L, LOCK_TYPE);
    int parent = parent_at(h->fd, name, 1, &base);
    if (parent < 0) return failure(L, "lock parent", errno);
    int fd = openat(parent, base, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
    int code = errno;
    close(parent);
    if (fd < 0) return failure(L, "open lock", code);
    struct stat status;
    if (fstat(fd, &status) < 0) {
        code = errno; close(fd); return failure(L, "lock stat", code);
    }
    if (!S_ISREG(status.st_mode)) { close(fd); return detail(L, "lock requires a regular file"); }
    /* POSIX record locks are process-owned. Keep one handle per lock file,
     * never replace it, and do not open/close that inode elsewhere while held.
     * This utility coordinates processes, not coroutines of one Lua state. */
    struct flock request = {0};
    request.l_type = F_WRLCK; request.l_whence = SEEK_SET;
    if (fcntl(fd, F_SETLK, &request) < 0) {
        code = errno; close(fd);
        return code == EACCES || code == EAGAIN ? detail(L, "busy") : failure(L, "lock", code);
    }
    lock->fd = fd;
    return 1;
}

static int fs_sha256(lua_State *L) {
    size_t length;
    const char *bytes = luaL_checklstring(L, 1, &length);
    unsigned char digest[32];
#if defined(__NetBSD__) || defined(__APPLE__)
    SHA256_CTX ctx;
    SHA256_Init(&ctx);
    SHA256_Update(&ctx, (const uint8_t *)bytes, length);
    SHA256_Final(digest, &ctx);
#else
    unsigned int count = 0;
    if (EVP_Digest(bytes, length, digest, &count, EVP_sha256(), NULL) != 1)
        return detail(L, "SHA-256 failed");
#endif
    char hex[65];
    for (unsigned int i = 0; i < sizeof digest; ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    lua_pushlstring(L, hex, 64);
    return 1;
}

static int fs_hash(lua_State *L) {
    struct handle *h = root_handle(L);
    const char *name = relative(L, 2, 0), *base;
    int parent = parent_at(h->fd, name, 0, &base);
    if (parent < 0) return failure(L, "hash parent", errno);
    int fd = openat(parent, base, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    int code = errno;
    close(parent);
    if (fd < 0) return failure(L, "hash", code);
    struct stat status;
    if (fstat(fd, &status) < 0) {
        code = errno; close(fd); return failure(L, "hash stat", code);
    }
    if (!S_ISREG(status.st_mode)) { close(fd); return detail(L, "hash requires a regular file"); }
#if defined(__NetBSD__) || defined(__APPLE__)
    SHA256_CTX ctx;
    int ok = SHA256_Init(&ctx);
#else
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    int ok = ctx && EVP_DigestInit_ex(ctx, EVP_sha256(), NULL) == 1;
    unsigned int count = 0;
#endif
    unsigned char buffer[4096], digest[32];
    code = 0;
    while (ok) {
        ssize_t n = read(fd, buffer, sizeof buffer);
        if (n < 0) { if (errno == EINTR) continue; code = errno; break; }
        if (n == 0) break;
#if defined(__NetBSD__) || defined(__APPLE__)
        ok = SHA256_Update(&ctx, buffer, (size_t)n);
#else
        ok = EVP_DigestUpdate(ctx, buffer, (size_t)n) == 1;
#endif
    }
    if (close(fd) < 0 && !code) code = errno;
#if defined(__NetBSD__) || defined(__APPLE__)
    if (ok && !code) ok = SHA256_Final(digest, &ctx);
#else
    if (ok && !code) ok = EVP_DigestFinal_ex(ctx, digest, &count) == 1 && count == 32;
    EVP_MD_CTX_free(ctx);
#endif
    if (code) return failure(L, "hash", code);
    if (!ok) return detail(L, "SHA-256 failed");
    char hex[65];
    for (unsigned int i = 0; i < sizeof digest; ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    lua_pushlstring(L, hex, 64);
    return 1;
}

int luaopen_asenta_fs(lua_State *L) {
    static const luaL_Reg methods[] = {
        {"read", fs_read}, {"write", fs_write}, {"mkdir", fs_mkdir},
        {"list", fs_list}, {"stat", fs_stat}, {"remove", fs_remove},
        {"rename", fs_rename}, {"lock", fs_lock}, {"hash", fs_hash}, {"close", close_handle},
        {NULL, NULL}
    };
    static const luaL_Reg module[] = {{"root", fs_root}, {"sha256", fs_sha256}, {NULL, NULL}};
    luaL_newmetatable(L, ROOT_TYPE);
    luaL_setfuncs(L, methods, 0);
    lua_pushvalue(L, -1); lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, close_handle); lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, close_handle); lua_setfield(L, -2, "__close");
    lua_pop(L, 1);
    luaL_newmetatable(L, LOCK_TYPE);
    lua_pushcfunction(L, close_handle); lua_setfield(L, -2, "close");
    lua_pushvalue(L, -1); lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, close_handle); lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, close_handle); lua_setfield(L, -2, "__close");
    lua_pop(L, 1);
    luaL_newlib(L, module);
    return 1;
}
