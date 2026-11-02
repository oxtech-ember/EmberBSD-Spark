#!/bin/sh
# Build and package the C/Lua application with shared Ports dependencies.
set -eu
LC_ALL=C
export LC_ALL
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=$source_dir/build/package
version=c-lua-development
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-dir) output=${2:?output directory is required}; shift 2;;
        --version) version=${2:?version is required}; shift 2;;
        --help|-h)
            echo 'Usage: build.sh [--output-dir DIR] [--version VERSION]'
            echo 'Requires common Ports Lua 5.5, libcurl and dkjson 2.11; no dependency downloads.'
            echo 'Select host tools with CC, MAKE, PKG_CONFIG, SPARK_HOST_LUA and SPARK_DKJSON.'
            exit 0;;
        *) echo "Unknown argument: $1" >&2; exit 2;;
    esac
done
case "$version" in ''|*[!a-zA-Z0-9._+-]*) echo 'Invalid version' >&2; exit 2;; esac
system=$(uname -s)
case "$system" in Darwin|Linux|NetBSD|FreeBSD) ;; *) echo "Unsupported native system: $system" >&2; exit 2;; esac
: "${SPARK_DKJSON:?set SPARK_DKJSON to the installed common dkjson 2.11 source}"
[ -f "$SPARK_DKJSON" ] || { echo 'Missing common dkjson source' >&2; exit 1; }
hash_file() {
    if command -v sha256 >/dev/null 2>&1; then sha256 -q "$1"
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}
[ "$(hash_file "$SPARK_DKJSON")" = 197cb50834c642f84b4cf99fe724932c50e6d9c92faec7ad89aa25e91df4d481 ] || {
    echo 'dkjson 2.11 SHA256 differs' >&2; exit 1;
}
make_command=${MAKE:-make}
compiler=${CC:-cc}
pkg_config=${PKG_CONFIG:-pkg-config}
interpreter=${SPARK_HOST_LUA:-lua5.5}
lua_package=${SPARK_LUA_PACKAGE:-lua-5.5}
readelf=${SPARK_READELF:-llvm-readelf}
otool=${SPARK_OTOOL:-llvm-otool}
enable_bluetooth=${SPARK_ENABLE_BLUETOOTH:-yes}
link_mode=${SPARK_LINK_MODE:-dynamic}
case "$enable_bluetooth" in yes|no) ;; *) echo 'SPARK_ENABLE_BLUETOOTH must be yes or no' >&2; exit 2;; esac
case "$link_mode" in dynamic|static) ;; *) echo 'SPARK_LINK_MODE must be dynamic or static' >&2; exit 2;; esac
if [ "$system" = Darwin ] && [ "$link_mode" = static ]; then
    echo 'Static linking is not supported by this Darwin build profile' >&2
    exit 2
fi
lua_version=$("$pkg_config" --modversion "$lua_package")
case "$lua_version" in 5.5|5.5.*) ;; *) echo "Expected Lua 5.5, found $lua_version" >&2; exit 1;; esac
command -v "$interpreter" >/dev/null 2>&1 || { echo "Missing selected Lua interpreter: $interpreter" >&2; exit 1; }
pkg_config_static=no
pkg_config_static_flag=
link_flags=${LDFLAGS:-}
if [ "$link_mode" = static ]; then
    pkg_config_static=yes
    pkg_config_static_flag=--static
    link_flags="$link_flags -static"
fi
if [ "$system" = Darwin ]; then
    # Keep the system curl default, but honor an explicitly selected host
    # pkg-config so prefix-built dependencies do not resolve to system curl.
    if [ -n "${CURL_LIBS:-}" ]; then
        curl_cflags=${CURL_CFLAGS:-}
        curl_libs=$CURL_LIBS
    elif [ -n "${PKG_CONFIG:-}" ]; then
        curl_cflags=${CURL_CFLAGS:-$("$pkg_config" --cflags libcurl)}
        curl_libs=$("$pkg_config" $pkg_config_static_flag --libs libcurl)
    else
        curl_cflags=${CURL_CFLAGS:-}
        curl_libs=-lcurl
    fi
else
    curl_cflags=${CURL_CFLAGS:-$("$pkg_config" --cflags libcurl)}
    curl_libs=${CURL_LIBS:-$("$pkg_config" $pkg_config_static_flag --libs libcurl)}
fi
case "$system" in
    Darwin|NetBSD) crypto_cflags=; crypto_libs=;;
    *) crypto_cflags=${CRYPTO_CFLAGS:-$("$pkg_config" --cflags libcrypto)}
       crypto_libs=${CRYPTO_LIBS:-$("$pkg_config" $pkg_config_static_flag --libs libcrypto)};;
esac
case "$system" in
    Linux) module_flags='-Wl,-E -ldl';;
    NetBSD|FreeBSD) module_flags=-Wl,-E;;
    Darwin) module_flags=;;
esac
lua_cflags=$("$pkg_config" --cflags "$lua_package")
lua_libs=$("$pkg_config" $pkg_config_static_flag --libs "$lua_package")
stage=$(mktemp -d "${TMPDIR:-/tmp}/oxtorg-native.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
build_dir=$stage/objects
mkdir -p "$build_dir"
"$make_command" -C "$source_dir" TARGET_OS="$system" BUILD_DIR="$build_dir" \
    LUA_PACKAGE="$lua_package" ENABLE_BLUETOOTH="$enable_bluetooth" \
    PKG_CONFIG_STATIC="$pkg_config_static" PKG_CONFIG="$pkg_config" CC="$compiler" \
    CFLAGS="${CFLAGS:--Os -std=c99 -Wall -Wextra -Werror}" CPPFLAGS="${CPPFLAGS:-}" \
    LDFLAGS="$link_flags" LUA_CFLAGS="$lua_cflags" LUA_LIBS="$lua_libs $module_flags" \
    CURL_CFLAGS="$curl_cflags" CURL_LIBS="$curl_libs" \
    CRYPTO_CFLAGS="$crypto_cflags" CRYPTO_LIBS="$crypto_libs" \
    "$build_dir/agent-lua"
"$interpreter" "$source_dir/package.lua" "$SPARK_DKJSON" "$version" \
    "$stage/oxtorg-agent.lua" "$source_dir"/lua/*.lua
cp "$build_dir/agent-lua" "$stage/agent-lua"
cp "$build_dir/agent-lua" "$stage/oxtorg-agent"
cp "$source_dir/LICENSE" "$stage/LICENSE"
cp "$source_dir/THIRD-PARTY.md" "$stage/THIRD-PARTY.md"
printf '%s\n' "$version" > "$stage/BUILD"
{
    printf 'runtime=C99 + Lua 5.5 (%s)\ndkjson=2.11\nsystem=%s\narchitecture=%s\n' "$lua_package" "$system" "$(uname -m)"
    printf 'Bluetooth=%s\nLink mode=%s\n' "$enable_bluetooth" "$link_mode"
    printf '%s\n' 'Lua and dkjson are supplied by common Ports. The following libraries and TLS trust store are provided by the destination OS.'
    if [ "$system" = Darwin ]; then "$otool" -L "$stage/oxtorg-agent" | sed '1d'
    else "$readelf" -d "$stage/oxtorg-agent" | awk '/\(NEEDED\)/ { print $NF }'; fi
    printf '\nEmberBSD-Spark license:\n'
    cat "$source_dir/LICENSE"
} > "$stage/runtime-dependencies.txt"
test "$("$stage/oxtorg-agent" -version)" = "$version"
"$stage/oxtorg-agent" -capabilities >/dev/null
mkdir -p "$output"
output=$(CDPATH= cd -- "$output" && pwd)
for name in agent-lua oxtorg-agent oxtorg-agent.lua BUILD runtime-dependencies.txt LICENSE THIRD-PARTY.md; do
    cp "$stage/$name" "$output/$name.new"
    mv "$output/$name.new" "$output/$name"
done
printf 'Native agent package: %s\n' "$output"
