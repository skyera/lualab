#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}

int main(void) {
    char *line = NULL;
    size_t len = 0;
    int error;
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    while (getline(&line, &len, stdin) != -1) {
        error = luaL_loadstring(L, line) || lua_pcall(L, 0, 0, 0);
        if (error) {
            fprintf(stderr, "%s\n", lua_tostring(L, -1));
            lua_pop(L, 1);
        }
    }
    free(line);
    lua_close(L);
    return 0;
}

