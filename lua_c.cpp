// https://lucasklassmann.com/blog/2019-02-02-embedding-lua-in-c/

// Compile:
// g++ lua_c.cpp -o lua_c  -I/home/pi/test/luajit/src/ ~/test/luajit/src/libluajit.a  -ldl -lreadline
// g++ lua_c.cpp -o lua_c -llua -ldl
extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}
#include <assert.h>

int multiplication(lua_State* L) {
    int a = luaL_checkinteger(L, 1);
    int b = luaL_checkinteger(L, 2);
    lua_Integer c = a * b;
    lua_pushinteger(L, c);
    return 1;
}

void register_functions(lua_State *L, const luaL_Reg* funcs) {
    for (; funcs->name != nullptr; ++funcs) {
        lua_pushcfunction(L, funcs->func);
        //lua_setglobal(L, funcs->name);
        lua_setfield(L, -2, funcs->name);
    }
}

struct Foo {
    int x;
    int y;
};

int create_foo(lua_State* L) {
    Foo* foo = static_cast<Foo*>(lua_newuserdata(L, sizeof(Foo)));
    foo->x = 0;
    foo->y = 0;
    
    printf("created Foo in C\n");
    return 1;
}

int main(int argc, char** argv) {
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    
    {
        char code[] = "print('Hello, World')";

        if (luaL_loadstring(L, code) == LUA_OK) {
            if (lua_pcall(L, 0, 0, 0) == LUA_OK) {
                lua_pop(L, lua_gettop(L));
            }
        }
    }

    {
        lua_pushinteger(L, 42);
        lua_setglobal(L, "answer");

        char code[] = "print(answer)";
        if (luaL_dostring(L, code) == LUA_OK) {
            lua_pop(L, lua_gettop(L));
        }
    }
    
    {
        lua_pushcfunction(L, multiplication);
        lua_setglobal(L, "mul");

        char code[] = "print(mul(7, 8))";
        if (luaL_dostring(L, code) == LUA_OK) {
            lua_pop(L, lua_gettop(L));
        }
    }

    {
        const struct luaL_Reg MyMathLib[] = {
            {"mul", multiplication}
        };
        
        lua_newtable(L);
        lua_pushcfunction(L, multiplication);
        lua_setfield(L, -2, "mul");
        lua_setglobal(L, "MyMath");

        char code[] = "print(MyMath.mul(7, 8))";
        if (luaL_dostring(L, code) == LUA_OK) {
            lua_pop(L, lua_gettop(L));
        }
    }

    {
        luaL_dostring(L, "x=42; message='test'");
        lua_getglobal(L, "x");

        if (lua_isnumber(L, -1)) {
            double x_value = lua_tonumber(L, -1);
            printf("value x is: %.f\n", x_value);
        }
        lua_pop(L, 1);

        lua_getglobal(L, "message");
        if (lua_isstring(L, -1)) {
            const char* message = lua_tostring(L, -1);
            printf("Message from lua: %s\n", message);
        }
        lua_pop(L, 1);
    }

    {
        char code[] = "function my_func(a, b) return a * b end";
        if (luaL_dostring(L, code) == LUA_OK) {
            lua_pop(L, lua_gettop(L));
        }

        lua_getglobal(L, "my_func");
        lua_pushinteger(L, 3);
        lua_pushinteger(L, 4);

        if (lua_pcall(L, 2, 1, 0) == LUA_OK) {
            int result = luaL_checkinteger(L, -1);
            lua_pop(L, 1);
            printf("Result: %d\n", result);
        }
        lua_pop(L, lua_gettop(L));
    }

    {
        lua_pushcfunction(L, create_foo);
        lua_setglobal(L, "create_foo");

        char code[] = "foo = create_foo();print('created userdata Foo')";
        luaL_dostring(L, code);
        lua_pop(L, lua_gettop(L));
    }

    {
        char code[] = "foo1 = { foo_number=1, bar_number=2, foo_string=\"foo\", bar_string=\"bar\"}";
        
        luaL_dostring(L, code);
        lua_getglobal(L, "foo1");

        if (lua_istable(L, -1)) {
            int stack_size = lua_gettop(L);
            printf("stack size: %d\n", stack_size);

            auto ok = lua_getfield(L, -1, "foo_number");
            printf("stack size: %d\n", stack_size);
            assert(ok == LUA_TNUMBER);
            auto foo_number = lua_tonumber(L, -1);
            printf("foo_number %f\n", foo_number);
            printf("stack size: %d\n", stack_size);

            ok = lua_getfield(L, -2, "bar_number");
            assert(ok == LUA_TNUMBER);
            auto bar_number = lua_tonumber(L, -1);
            printf("stack size: %d\n", stack_size);

            ok = lua_getfield(L, -3, "foo_string");
            assert(ok == LUA_TSTRING);
            const char* foo_string = lua_tostring(L, -1);

            ok = lua_getfield(L, -4, "bar_string");
            assert(ok == LUA_TSTRING);
            const char* bar_string = lua_tostring(L, -1);

            printf("%f %f\n", foo_number, bar_number);
            printf("%s %s\n", foo_string, bar_string);
        }
    }

    lua_close(L);
    return 0;
}