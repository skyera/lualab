// build: make embed1.cpp -o embed1 -I/path/include /path/libluajit.a -ldl

// compile: 
// g++ embed1.cpp -o embed1 -I/home/pi/test/luajit/src/ ~/test/luajit/src/libluajit.a  -ldl

// export CPLUS_INCLUDE_PATH="/home/pi/test/LuaBridge/Source/LuaBridge:/home/pi/test/LuaBridge/Source:$CPLUS_INCLUDE_PATH"
//g++ embed1.cpp -o embed1 -I/home/pi/test/luajit/src/ ~/test/luajit/src/libluajit.a  -ldl -lreadline

#include <readline/readline.h>
#include <readline/history.h>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}

#include "LuaBridge.h"
using namespace luabridge;
        
LuaRef CreateTable(lua_State* L) {
    LuaRef table = LuaRef::newTable(L);

    table["name"] = std::string("Lua");
    table["version"] = 1.0;
    table["active"] = true;
    return table;
}

int bar_func() {
	return 2;
}

int main(int argc, char** argv) {
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);

    getGlobalNamespace(L)
        .beginNamespace("foo")
        .addFunction("create_table", CreateTable)
        .addFunction("bar", bar_func)
        .endNamespace();
    
    if (argc == 2 ) {
        lua_newtable(L);
        for (int i = 1; i < argc; ++i) {
            lua_pushnumber(L, i-1);
            lua_pushstring(L, argv[i]);
            lua_settable(L, -3);
        }
        lua_setglobal(L, "arg");

        char* filename = argv[1];
        int result = luaL_loadfile(L, filename);

        if (result != 0) {
            printf("Could not load %s\n", filename);
            lua_pop(L, 1);
            lua_close(L);
            return -1;
        }

        result = lua_pcall(L, 0, 0, 0);
        if (result != 0) {
            const char* error = lua_tostring(L, -1);
            printf("Error %s\n", error);
            lua_pop(L, 1);
            lua_close(L);
            return -1;;
        }
    } else {
        char* input;
        while ((input = readline("> ")) != nullptr) {
            if (std::string(input) == "exit") {
                free(input);
                break;
            }
            if (*input) add_history(input);

            // Step 5: Execute Lua code from input
            if (luaL_dostring(L, input) != LUA_OK) {
                // If an error occurred, print the error message
                std::cerr << lua_tostring(L, -1) << std::endl;
                lua_pop(L, 1);  // Remove error message from stack
            }
        }
    }
    printf("Done\n");
    lua_close(L);
    return 0;
}
