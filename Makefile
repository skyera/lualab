# Compiler and flags
CXX = g++
LUAJIT_DIR = LuaJIT
LUAJIT_INC = $(LUAJIT_DIR)/src
LUAJIT_LIB = $(LUAJIT_DIR)/src/libluajit.a

CXXFLAGS = -Wall -O2 -std=c++11 -ILuaBridge/Source/LuaBridge -ILuaBridge/Source -I$(LUAJIT_INC)

# Files to compile
SRC = embed_luabridge_demo.cpp embed_custom_userdata.cpp embed_stack_api.cpp embed_repl_simple.cpp

# Output binaries
BIN1 = embed1
BIN2 = lua_c
BIN3 = lua_c1
BIN4 = lua_c2

# Linking libraries (LuaJIT, libdl, libreadline)
LIBS = $(LUAJIT_LIB) -ldl -lreadline

# Targets
all: $(LUAJIT_LIB) $(BIN1) $(BIN2) $(BIN3) $(BIN4)

$(LUAJIT_LIB):
	cd $(LUAJIT_DIR) && $(MAKE)

$(BIN1): embed_luabridge_demo.cpp $(LUAJIT_LIB)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LIBS)

$(BIN2): embed_custom_userdata.cpp $(LUAJIT_LIB)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LIBS)

$(BIN3): embed_stack_api.cpp $(LUAJIT_LIB)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LIBS)

$(BIN4): embed_repl_simple.cpp $(LUAJIT_LIB)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LIBS)

# Clean up
clean:
	rm -f $(BIN1) $(BIN2) $(BIN3) $(BIN4)

clean-all: clean
	cd $(LUAJIT_DIR) && $(MAKE) clean
