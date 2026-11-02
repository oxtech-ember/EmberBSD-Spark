#!/bin/sh
# Cross-build the Spark application with the common EmberBSD Lua library.
set -eu

: "${SPARK_SYSROOT:?set SPARK_SYSROOT to the EmberBSD sysroot}"
: "${SPARK_CC:?set SPARK_CC to the selected EmberBSD target compiler driver}"
: "${SPARK_DKJSON:?set SPARK_DKJSON to the verified dkjson 2.11 source}"

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
target=${SPARK_TARGET:-aarch64}
build_dir=${SPARK_BUILD_DIR:-"$source_dir/build/emberbsd-$target"}
make_command=${SPARK_MAKE:-gmake}
interpreter=${SPARK_HOST_LUA:-lua5.5}
pkg_config=${SPARK_PKG_CONFIG:-${PKG_CONFIG:-pkg-config}}
lua_package=${SPARK_LUA_PACKAGE:-lua-5.5}
readelf=${SPARK_READELF:-llvm-readelf}
enable_bluetooth=${SPARK_ENABLE_BLUETOOTH:-yes}
link_mode=${SPARK_LINK_MODE:-dynamic}
version=${SPARK_VERSION:-spark-development}
case "$version" in ''|*[!a-zA-Z0-9._+-]*) echo 'Invalid Spark version' >&2; exit 2;; esac
case "$target" in ''|*[!a-zA-Z0-9._+-]*) echo 'Invalid Spark target label' >&2; exit 2;; esac
case "$enable_bluetooth" in yes|no) ;; *) echo 'SPARK_ENABLE_BLUETOOTH must be yes or no' >&2; exit 2;; esac
case "$link_mode" in dynamic|static) ;; *) echo 'SPARK_LINK_MODE must be dynamic or static' >&2; exit 2;; esac

case "$SPARK_SYSROOT" in /*) ;; *) echo 'SPARK_SYSROOT must be absolute' >&2; exit 2;; esac
case "$SPARK_CC" in /*) ;; *) echo 'SPARK_CC must be absolute' >&2; exit 2;; esac
[ -d "$SPARK_SYSROOT/usr/include" ] || { echo 'Missing EmberBSD headers' >&2; exit 1; }
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
unset PKG_CONFIG_PATH
lua_version=$("$pkg_config" --modversion "$lua_package")
case "$lua_version" in 5.5|5.5.*) ;; *) echo "Expected Lua 5.5, found $lua_version" >&2; exit 1;; esac
pkg_config_static=no
link_flags="--sysroot=$SPARK_SYSROOT -Wl,-E -Wl,-rpath-link,$SPARK_SYSROOT/usr/pkg/lib"
if [ "$link_mode" = static ]; then
    pkg_config_static=yes
    link_flags="$link_flags -static"
fi
# Compiler, sysroot, and pkg-config inputs are not Makefile prerequisites.
# Build in a fresh sibling directory so a failed build preserves the last
# checked package and Make cannot reuse objects from another mode.
build_parent=$(dirname "$build_dir")
build_name=$(basename "$build_dir")
mkdir -p "$build_parent"
build_parent=$(CDPATH= cd -- "$build_parent" && pwd)
build_dir="$build_parent/$build_name"
stage=$(mktemp -d "$build_parent/.${build_name}.stage.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
"$make_command" -C "$source_dir" TARGET_OS=NetBSD BUILD_DIR="$stage" \
    LUA_PACKAGE="$lua_package" ENABLE_BLUETOOTH="$enable_bluetooth" PKG_CONFIG_STATIC="$pkg_config_static" \
    PKG_CONFIG="$pkg_config" CC="$SPARK_CC" \
    CPPFLAGS="--sysroot=$SPARK_SYSROOT" \
    LDFLAGS="$link_flags" all
"$interpreter" "$source_dir/package.lua" "$SPARK_DKJSON" "$version" \
    "$stage/oxtorg-agent.lua" "$source_dir"/lua/*.lua
cp "$stage/agent-lua" "$stage/oxtorg-agent"
cp "$source_dir/LICENSE" "$stage/LICENSE"
cp "$source_dir/THIRD-PARTY.md" "$stage/THIRD-PARTY.md"
{
    printf 'Spark version: %s\nTarget: %s\nLink mode: %s\nBluetooth: %s\nLua: 5.5\ndkjson: 2.11\n' \
        "$version" "$target" "$link_mode" "$enable_bluetooth"
} > "$stage/runtime-dependencies.txt"
if [ "$link_mode" = dynamic ]; then
    "$readelf" -d "$stage/oxtorg-agent" > "$stage/runtime-elf.txt"
    awk '/\(NEEDED\)/ { print $NF }' "$stage/runtime-elf.txt" >> "$stage/runtime-dependencies.txt"
else
    "$readelf" -h "$stage/oxtorg-agent" > "$stage/runtime-elf.txt"
    printf 'Target dependencies are statically linked.\n' >> "$stage/runtime-dependencies.txt"
fi
printf '%s\n' "$version" > "$stage/BUILD"
mkdir -p "$build_dir"
for name in agent-lua oxtorg-agent oxtorg-agent.lua LICENSE THIRD-PARTY.md \
    runtime-dependencies.txt runtime-elf.txt BUILD; do
    [ -f "$stage/$name" ] || continue
    cp "$stage/$name" "$build_dir/$name.new"
    mv "$build_dir/$name.new" "$build_dir/$name"
done
if [ "$enable_bluetooth" = no ]; then
    rm -f "$build_dir/bluetooth-admin"
elif [ -f "$stage/bluetooth-admin" ]; then
    cp "$stage/bluetooth-admin" "$build_dir/bluetooth-admin.new"
    mv "$build_dir/bluetooth-admin.new" "$build_dir/bluetooth-admin"
fi
printf 'EmberBSD Spark package: %s\n' "$build_dir"
