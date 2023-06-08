// Lua C library to simply return a userdata -- for benchmarking object creation
// Compile with:
// gcc object_creation_c.c -o object_creation_c.so -shared -O3 -fPIC

#include <lua.h>
#include <lauxlib.h>

int userdata(lua_State *L) {
  int size = luaL_checkinteger(L, 1);
  lua_newuserdata(L, size);
  return 1;
}

int lightuserdata(lua_State *L) {
  static int x;
  lua_pushlightuserdata(L, (void*)&x);
  return 1;
}

static const luaL_Reg c_functions[] = {
  {"userdata", userdata},
  {"lightuserdata", lightuserdata},
  {NULL, NULL},
};

int luaopen_object_creation_c(lua_State *L) {
  luaL_newlib(L, c_functions);
  return 1;
}
