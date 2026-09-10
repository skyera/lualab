# lualab
```
| |_   _  __ _  | | __ _| |__  
| | | | |/ _` | | |/ _` | '_ \ 
| | |_| | (_| | | | (_| | |_) |
|_|\__,_|\__,_| |_|\__,_|_.__/ 
```

A collection of Lua embedding examples using LuaJIT and LuaBridge.

## Prerequisites
Ensure you have the following installed on your system:
- `g++` (C++11 or later)
- `make`
- `libreadline-dev`

## Getting Started

### 1. Clone the repository
This project uses submodules for LuaJIT and LuaBridge. Clone with the `--recurse-submodules` flag:
```bash
git clone --recurse-submodules https://github.com/skyera/lualab.git
cd lualab
```
If you have already cloned the repository, initialize submodules with:
```bash
git submodule update --init --recursive
```

### 2. Build
Run `make` to build all binaries. This will automatically build the LuaJIT submodule if it hasn't been built yet.
```bash
make
```

### 3. Run
- **Interactive Shell (with C++ bindings):**
  ```bash
  ./demo_luabridge
  ```
- **Execute a script:**
  ```bash
  ./demo_luabridge scratch_lua_features.lua
  ```
- **Run other examples:**
  ```bash
  ./demo_custom_userdata   # Creating custom C types for Lua
  ./demo_stack_api        # Low-level Lua stack manipulation
  ./demo_repl             # Simple interactive REPL
  ```

- **Run FFI Examples (requires LuaJIT):**
  ```bash
  ./LuaJIT/src/luajit ffi_system_info.lua
  ./LuaJIT/src/luajit ffi_advanced_demo.lua
  ./LuaJIT/src/luajit ffi_sqlite_demo.lua   # In-memory SQLite3 FFI engine & benchmark
  ./LuaJIT/src/luajit game_snake_ffi.lua    # Real-time terminal Snake game via POSIX FFI
  ./LuaJIT/src/luajit ffi_image_terminal_demo.lua  # Fast C image generation & terminal truecolor viewer
  ./LuaJIT/src/luajit view_image_terminal.lua <image.png|jpg|ppm>  # Terminal image viewer with auto-scaling
  ./LuaJIT/src/luajit gallery_portrait.lua  # Dynamic procedural portrait gallery with interactive selection
  ```

- **Run Unit Tests:**
  ```bash
  make test
  # or directly:
  ./LuaJIT/src/luajit test_ffi_suite.lua
  ```

## Maintenance
- **Remove binaries:** `make clean`
- **Remove binaries and clean submodules:** `make clean-all`

## Reference
* [LuaBridge](https://github.com/vinniefalco/LuaBridge)
* [LuaJIT](https://github.com/LuaJIT/LuaJIT)
* [Lua Quick Start Guide](https://github.com/PacktPublishing/Lua-Quick-Start-Guide)
* [Awesome Lua](https://github.com/LewisJEllis/awesome-lua)
* [lua-users.org](http://lua-users.org/)
