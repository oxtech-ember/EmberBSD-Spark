#ifndef OXTORG_LUA_HOST_H
#define OXTORG_LUA_HOST_H
#include <lua.h>
#if LUA_VERSION_NUM != 505
#error "EmberBSD-Spark requires the common Lua 5.5 ABI"
#endif
int host_http(lua_State *L);
void host_http_close(void);
int luaopen_asenta_fs(lua_State *L);
int host_fs_dup_root(lua_State *L, int index);
int luaopen_asenta_equipment(lua_State *L);
int luaopen_asenta_bluetooth(lua_State *L);
int luaopen_asenta_obd(lua_State *L);
int luaopen_asenta_process(lua_State *L);
void host_process_close(void);
void host_process_signal(int signal_number);
void host_bluetooth_signal(int signal_number);
int host_service_open(void);
void host_service_release(void);
void host_log(int error, const char *message);
#endif
