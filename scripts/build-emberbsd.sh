#!/bin/sh
# Cross-build the Spark application with the common EmberBSD Lua library.
set -eu

: "${SPARK_SYSROOT:?set SPARK_SYSROOT to the EmberBSD sysroot}"
: "${SPARK_CC:?set SPARK_CC to the EmberBSD GCC 16 compiler}"
: "${SPARK_DKJSON:?set SPARK_DKJSON to the verified dkjson 2.11 source}"

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=${SPARK_BUILD_DIR:-"$source_dir/build/emberbsd-aarch64"}
make_command=${SPARK_MAKE:-gmake}
interpreter=${SPARK_HOST_LUA:-lua5.5}
version=${SPARK_VERSION:-spark-development}
case "$version" in ''|*[!a-zA-Z0-9._+-]*) echo 'Invalid Spark version' >&2; exit 2;; esac

case "$SPARK_SYSROOT" in /*) ;; *) echo 'SPARK_SYSROOT must be absolute' >&2; exit 2;; esac
case "$SPARK_CC" in /*) ;; *) echo 'SPARK_CC must be absolute' >&2; exit 2;; esac
[ -d "$SPARK_SYSROOT/usr/include" ] || { echo 'Missing EmberBSD headers' >&2; exit 1; }
[ -f "$SPARK_SYSROOT/usr/include/lua.h" ] || { echo 'Missing common Lua header' >&2; exit 1; }
[ -f "$SPARK_SYSROOT/usr/lib/liblua.so.7" ] || [ -L "$SPARK_SYSROOT/usr/lib/liblua.so.7" ] || {
    echo 'Missing common Lua 5.5 ABI 7 library' >&2; exit 1;
}
[ -f "$SPARK_DKJSON" ] || { echo 'Missing dkjson source' >&2; exit 1; }
if command -v sha256 >/dev/null 2>&1; then
    actual=$(sha256 -q "$SPARK_DKJSON")
else
    actual=$(shasum -a 256 "$SPARK_DKJSON" | awk '{print $1}')
fi
[ "$actual" = 197cb50834c642f84b4cf99fe724932c50e6d9c92faec7ad89aa25e91df4d481 ] || {
    echo 'dkjson 2.11 SHA256 differs' >&2; exit 1;
}

export PKG_CONFIG_SYSROOT_DIR="$SPARK_SYSROOT"
export PKG_CONFIG_LIBDIR="$SPARK_SYSROOT/usr/pkg/lib/pkgconfig:$SPARK_SYSROOT/usr/lib/pkgconfig"
"$make_command" -C "$source_dir" TARGET_OS=NetBSD BUILD_DIR="$build_dir" \
    LUA_PACKAGE=lua CC="$SPARK_CC" \
    CPPFLAGS="--sysroot=$SPARK_SYSROOT" \
    LDFLAGS="--sysroot=$SPARK_SYSROOT -Wl,-E -Wl,-rpath-link,$SPARK_SYSROOT/usr/pkg/lib" all
"$interpreter" "$source_dir/package.lua" "$SPARK_DKJSON" "$version" \
    "$build_dir/oxtorg-agent.lua" "$source_dir"/lua/*.lua
cp "$build_dir/agent-lua" "$build_dir/oxtorg-agent"
printf '%s\n' "$version" > "$build_dir/BUILD"
printf 'EmberBSD Spark package: %s\n' "$build_dir"
