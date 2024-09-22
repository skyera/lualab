// compile
// g++ lua_c1.cpp -o lua_c1 -ldl  ~/test/luajit/src/libluajit.a
// g++ lua_c1.cpp -o lua_c1 -ldl  -lluajit
extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}
#include <string.h>

int main(int argc, char** argv) {
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);

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

    lua_close(L);
    return 0;
}
