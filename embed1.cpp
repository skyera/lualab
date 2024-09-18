// build: make embed1.cpp -o embed1 /path/libluajit.a -ldl
extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}

int main(int argc, char** argv) {
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    
    if (argc == 2) {
        char* filename = argv[1];
        int result = luaL_loadfile(L, filename);

        if (result != 0) {
            printf("Could not load %s\n", filename);
            lua_close(L);
            return -1;
        }

        result = lua_pcall(L, 0, 0, 0);
        if (result != 0) {
            const char* error = lua_tostring(L, -1);
            printf("Error %s\n", error);
            lua_close(L);
            return -1;;
        }
    }
    printf("Done\n");
    lua_close(L);
    return 0;
}
