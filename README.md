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
  ./demo_luabridge test.lua
  ```
- **Run other examples:**
  ```bash
  ./demo_custom_userdata   # Creating custom C types for Lua
  ./demo_stack_api        # Low-level Lua stack manipulation
  ./demo_repl             # Simple interactive REPL
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
