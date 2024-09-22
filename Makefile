# Compiler and flags
CXX = g++
CXXFLAGS = -Wall -O2 -std=c++11

# Files to compile
SRC = embed1.cpp lua_c.cpp lua_c1.cpp

# Output binaries
BIN1 = embed1
BIN2 = lua_c
BIN3 = lua_c1

# LuaJIT include and libraries (update paths if necessary)
#LUAJIT_INC = /usr/include/luajit-2.1
#LUAJIT_LIB = /usr/lib/x86_64-linux-gnu

# Linking libraries (LuaJIT, libdl, libreadline)
LIBS = -lluajit -ldl -lreadline

# Targets
all: $(BIN1) $(BIN2) $(BIN3)

$(BIN1): embed1.cpp
	$(CXX) $(CXXFLAGS) -o $@ $< $(LIBS)

$(BIN2): lua_c.cpp
	$(CXX) $(CXXFLAGS) -o $@ $< $(LIBS)

$(BIN3): lua_c1.cpp
	$(CXX) $(CXXFLAGS) -o $@ $< $(LIBS)

# Clean up
clean:
	rm -f $(BIN1) $(BIN2) $(BIN3)
