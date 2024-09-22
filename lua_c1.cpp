// compile
// g++ lua_c1.cpp -o lua_c1 -ldl  ~/test/luajit/src/libluajit.a
// g++ lua_c1.cpp -o lua_c1 -ldl  -lluajit
extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}
#include <string.h>

void print_stacksize(lua_State* L) {
    int stack_size = lua_gettop(L);
    printf("stack size: %d\n", stack_size);
}

int linear_index(lua_State* L, int row, int col) {

    // push function on stack
    lua_getglobal(L, "get_index");
    print_stacksize(L);

    if (lua_isnil(L, -1)) {
        printf("Error: get_index is nil\n");
        lua_pop(L, 1);
        return 0;
    }
    
    // push args on stack
    lua_pushnumber(L, row);
    lua_pushnumber(L, col);
    print_stacksize(L);
    int pcall = lua_pcall(L, 2, 1, 0);
    print_stacksize(L);
    int result = 0;
    if (pcall != 0) {
        const char* error = lua_tostring(L, -1);
        printf("error: %s\n", error);
        lua_pop(L, 1);
    } else {
        result = lua_tointeger(L, -1);
        lua_pop(L, 1);
    }
    return result;
}

int main(int argc, char** argv) {
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    
    {
        // C read lua vars
        char code[] = "class='Warrior';attack=56;defense=43";

        int result = luaL_dostring(L, code);
        if (result != 0 ) {
            const char* error = lua_tostring(L, -1);
            printf("cannot dostring %s\n", error);
            lua_pop(L, 1);
            lua_close(L);
            return -1;
        }

        int stack_base = lua_gettop(L);

        // push values on stack
        lua_getglobal(L, "class");
        lua_getglobal(L, "attack");
        lua_getglobal(L, "defense");

        // read values on stack
        const char* class_p = lua_tostring(L, stack_base + 1);
        char class_sz[32];
        strcpy(class_sz, class_p);
        int attack = lua_tointeger(L, stack_base + 2);
        int defense = lua_tointeger(L, stack_base + 3);

        // clean up stack
        lua_pop(L, 3);  
        printf("class=%s;attack=%d;defense=%d\n", class_sz, attack, defense);
    }

    {
        // create Lua vars in C
        lua_pushstring(L, "Warrior");
        lua_pushnumber(L, 56);
        lua_pushnumber(L, 43);

        lua_setglobal(L, "defense");
        lua_setglobal(L, "attack");
        lua_setglobal(L, "class");

        char code[] = "print('class ' .. class .. ' attack ' .. attack .. ' defense ' .. defense)";
        int result = luaL_dostring(L, code);
        if (result != 0) {
            const char* error = lua_tostring(L, -1);
            printf("error %s\n", error);
            lua_pop(L, lua_gettop(L));
            lua_close(L);
            return -1;
        }
    }

    {
        // C call lua function
        int result = luaL_loadfile(L, "findindex.lua");
        if (result != 0) {
            printf("cannot load lua\n");
            lua_close(L);
            return -1;
        }

        result = lua_pcall(L, 0, 0, 0);
        if (result != 0) {
            const char* error = lua_tostring(L, -1);
            printf("error: %s\n", error);
            lua_close(L);
            return -1;
        }

        int index = linear_index(L, 3, 5);
        printf("index for (3, 5): %d\n", index);
    }

    lua_close(L);
    return 0;
}
