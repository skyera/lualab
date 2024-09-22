/* | |_   _  __ _  | | __ _| |__ */  
/* | | | | |/ _` | | |/ _` | '_ \ */ 
/* | | |_| | (_| | | | (_| | |_) | */
/* |_|\__,_|\__,_| |_|\__,_|_.__/ */ 

// build: make embed1.cpp -o embed1 -I/path/include /path/libluajit.a -ldl

// compile: 
// g++ embed1.cpp -o embed1 -I/home/pi/test/luajit/src/ ~/test/luajit/src/libluajit.a  -ldl

// export CPLUS_INCLUDE_PATH="/home/pi/test/LuaBridge/Source/LuaBridge:/home/pi/test/LuaBridge/Source:$CPLUS_INCLUDE_PATH"
//g++ embed1.cpp -o embed1 -I/home/pi/test/luajit/src/ ~/test/luajit/src/libluajit.a  -ldl -lreadline
// MAC
//  g++ embed1.cpp -o embed1 -std=c++11 ~/test/luajit/src/libluajit.a -ldl -lreadline

#include <readline/readline.h>
#include <readline/history.h>
#include <vector>
#include <dirent.h>
#include <string>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}

#include "LuaBridge.h"
using namespace luabridge;


std::vector<std::string> list_files(const std::string& path) {
    std::vector<std::string> files;
    DIR* dir = opendir(path.c_str());
    if (dir == nullptr) {
        return files;
    }
    if (dir) {
        struct dirent* entry;
        while ((entry = readdir(dir)) != nullptr) {
            if (entry->d_type == DT_REG) {
                files.push_back(entry->d_name);
            }
        }
        closedir(dir);
    } else {
        printf("Could not open directory %s\n", path.c_str());
    }

    return files;
}

int lua_listfiles(lua_State* L) {
    std::string path = luaL_checkstring(L, 1);
    std::vector<std::string> files = list_files(path);
    lua_newtable(L);
    for (int i = 0; i < files.size(); ++i) {
        lua_pushnumber(L, i+1);
        lua_pushstring(L, files[i].c_str());
        lua_settable(L, -3);
    }
    return 1;
}

int lua_listfiles2(lua_State* L) {
    std::string path = luaL_checkstring(L, 1);
    std::vector<std::string> files = list_files(path);
    LuaRef file_table = LuaRef::newTable(L);
    for (int i = 0; i < files.size(); ++i) {
        file_table[i+1] = files[i];
    }
    push(L, file_table);
    return 1;
}
        
LuaRef create_table(lua_State* L) {
    LuaRef table = LuaRef::newTable(L);

    table["name"] = std::string("Lua");
    table["version"] = 1.0;
    table["active"] = true;
    return table;
}

int bar_func() {
	return 2;
}

class MyClass {
public:
    MyClass() {}
    void greet() {
        printf("Hello from C++\n");
    }
};

int main(int argc, char** argv) {
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);

    getGlobalNamespace(L)
        .beginNamespace("foo")
        .addFunction("create_table", create_table)
        .addFunction("bar", bar_func)
        .addFunction("list_files", lua_listfiles)
        .addFunction("list_files2", lua_listfiles2)
        .endNamespace();

    getGlobalNamespace(L)
        .beginNamespace("test")
        .beginClass<MyClass>("MyClass")
            .addConstructor<void(*)(void)>()
            .addFunction("greet", &MyClass::greet)
        .endClass()
        .endNamespace();

    {
        // Lua call C class, function
        char code[] = "obj=test.MyClass();obj:greet()";
        auto result = luaL_dostring(L, code);
        if (result != 0 ) {
            const char* error = lua_tostring(L, -1);
            printf("cannot dostring %s\n", error);
            lua_pop(L, 1);
        }
    }

    {
        // C read Lua variables
        char code[] = "x=42; message='hello'; myt={a=1,b='foo'};";
        auto result = luaL_dostring(L, code);
        if (result != 0 ) {
            const char* error = lua_tostring(L, -1);
            printf("cannot dostring %s\n", error);
            lua_pop(L, 1);
        }

        int x = getGlobal(L, "x");
        std::string message = getGlobal(L, "message");
        LuaRef myt = getGlobal(L, "myt");
        printf("x=%d message=%s\n", x, message.c_str());

        if (myt.isTable()) {
            int a = myt["a"];
            std::string b = myt["b"];
            printf("myt.a=%d myt.b=%s\n", a, b.c_str());
        }
    }
    
    if (argc == 2 ) {
        // pass args to Lua
        lua_newtable(L);
        for (int i = 1; i < argc; ++i) {
            lua_pushnumber(L, i-1);
            lua_pushstring(L, argv[i]);
            lua_settable(L, -3);
        }
        lua_setglobal(L, "arg");
        
        // run lua script
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

            if (luaL_dostring(L, input) != LUA_OK) {
                std::cerr << lua_tostring(L, -1) << std::endl;
                lua_pop(L, 1);
            }
        }
    }
    printf("Done\n");
    lua_close(L);
    return 0;
}
