#!/bin/sh
# Native C + Lua application delivery. Lua/dkjson are pinned; the operating
# system supplies curl, TLS, libc and (outside macOS/NetBSD) libcrypto.
set -eu
LC_ALL=C
export LC_ALL
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=$source_dir/build/package
inputs=$source_dir/build/dependencies
version=c-lua-development
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-dir) output=${2:?output directory is required}; shift 2;;
        --version) version=${2:?version is required}; shift 2;;
        --inputs) inputs=${2:?input directory is required}; shift 2;;
        --help|-h)
            echo 'Usage: build.sh [--output-dir DIR] [--version VERSION] [--inputs DIR]'
            echo 'Native build; CC, CFLAGS, CURL_CFLAGS/CURL_LIBS, CRYPTO_CFLAGS/CRYPTO_LIBS and MAKE may be overridden.'
            echo 'Lua 5.4.8 and dkjson 2.11 are downloaded if missing, then checked by SHA256.'
            echo 'The destination OS must provide the dynamic libraries listed in runtime-dependencies.txt.'
            exit 0;;
        *) echo "Unknown argument: $1" >&2; exit 2;;
    esac
done
case "$version" in ''|*[!a-zA-Z0-9._+-]*) echo 'Invalid version' >&2; exit 2;; esac
system=$(uname -s)
case "$system" in Darwin|Linux|NetBSD|FreeBSD) ;; *) echo "Unsupported native system: $system" >&2; exit 2;; esac
mkdir -p "$inputs" "$output"
inputs=$(CDPATH= cd -- "$inputs" && pwd)
output=$(CDPATH= cd -- "$output" && pwd)
stage=$(mktemp -d "${TMPDIR:-/tmp}/oxtorg-native.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
hash_file() {
    if command -v sha256 >/dev/null 2>&1; then sha256 -q "$1"
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}
fetch() {
    name=$1 url=$2 expected=$3
    if [ ! -f "$inputs/$name" ]; then
        curl --fail --location --retry 3 --output "$stage/$name" "$url"
        [ "$(hash_file "$stage/$name")" = "$expected" ] || { echo "Checksum differs: $name" >&2; exit 1; }
        mv "$stage/$name" "$inputs/$name"
    fi
    [ "$(hash_file "$inputs/$name")" = "$expected" ] || { echo "Checksum differs: $name" >&2; exit 1; }
}
fetch lua-5.4.8.tar.gz https://www.lua.org/ftp/lua-5.4.8.tar.gz 4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae
fetch dkjson-2.11.lua https://dkolf.de/dkjson-lua/dkjson-2.11.lua 197cb50834c642f84b4cf99fe724932c50e6d9c92faec7ad89aa25e91df4d481
tar -xzf "$inputs/lua-5.4.8.tar.gz" -C "$stage"
make_command=${MAKE:-make}
compiler=${CC:-cc}
"$make_command" -C "$stage/lua-5.4.8/src" -j "${OXTORG_BUILD_JOBS:-3}" a \
    CC="$compiler" CFLAGS="${CFLAGS:--Os -std=c99} -DLUA_USE_POSIX -DLUA_USE_DLOPEN"
pkg_config=${PKG_CONFIG:-pkg-config}
if [ "$system" = Darwin ]; then
    # SDK headers and the OS curl keep the desktop package independent of brew.
    curl_cflags=${CURL_CFLAGS:-}
    curl_libs=${CURL_LIBS:--lcurl}
else
    curl_cflags=${CURL_CFLAGS:-$("$pkg_config" --cflags libcurl)}
    curl_libs=${CURL_LIBS:-$("$pkg_config" --libs libcurl)}
fi
case "$system" in
    Darwin|NetBSD) crypto_cflags=; crypto_libs=;;
    *)
        crypto_cflags=${CRYPTO_CFLAGS:-$("$pkg_config" --cflags libcrypto)}
        crypto_libs=${CRYPTO_LIBS:-$("$pkg_config" --libs libcrypto)};;
esac
case "$system" in
    Linux) module_flags='-Wl,-E -ldl';;
    NetBSD|FreeBSD) module_flags=-Wl,-E;;
    Darwin) module_flags=;;
esac
"$make_command" -C "$source_dir" "BUILD_DIR=$stage/host" \
    "CC=$compiler" "PKG_CONFIG=$pkg_config" \
    "CFLAGS=${CFLAGS:--Os -std=c99 -Wall -Wextra -Werror}" "CPPFLAGS=${CPPFLAGS:-}" "LDFLAGS=${LDFLAGS:-}" \
    "LUA_CFLAGS=-I$stage/lua-5.4.8/src" "LUA_LIBS=$stage/lua-5.4.8/src/liblua.a $module_flags" \
    "CRYPTO_CFLAGS=$crypto_cflags" "CRYPTO_LIBS=$crypto_libs" \
    "CURL_CFLAGS=$curl_cflags" "CURL_LIBS=$curl_libs" "$stage/host/agent-lua"
"$stage/host/agent-lua" "$source_dir/package.lua" "$inputs/dkjson-2.11.lua" \
    "$version" "$stage/oxtorg-agent.lua" "$source_dir"/lua/*.lua
cp "$stage/host/agent-lua" "$stage/oxtorg-agent"
printf '%s\n' "$version" >"$stage/BUILD"
{
    printf 'runtime=C99 + Lua 5.4.8\ndkjson=2.11\nsystem=%s\narchitecture=%s\n' "$system" "$(uname -m)"
    printf '%s\n' 'Lua and dkjson are included. The following libraries and their TLS trust store are provided by the destination OS.'
    if [ "$system" = Darwin ]; then otool -L "$stage/oxtorg-agent" | sed '1d'
    else ldd "$stage/oxtorg-agent" | sed '1{/^[^[:space:]]/d;}; s/ (0x[0-9a-fA-F]*)//g'; fi
    printf '\nLua license:\n'
    sed -n '/^\* Copyright/,/^\*\*\*\*/p' "$stage/lua-5.4.8/src/lua.h"
    printf '\ndkjson license is preserved in oxtorg-agent.lua.\n'
    printf '\nEmberBSD-Spark license:\n'
    cat "$source_dir/LICENSE"
} >"$stage/runtime-dependencies.txt"
test "$("$stage/oxtorg-agent" -version)" = "$version"
"$stage/oxtorg-agent" -capabilities >/dev/null
for name in oxtorg-agent oxtorg-agent.lua BUILD runtime-dependencies.txt; do
    cp "$stage/$name" "$output/$name.new"
    mv "$output/$name.new" "$output/$name"
done
printf 'Native agent package: %s\n' "$output"
