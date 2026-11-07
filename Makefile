# Compiler and flags
CXX = g++
LUAJIT_DIR = LuaJIT
LUAJIT_INC = $(LUAJIT_DIR)/src
LUAJIT_LIB = $(LUAJIT_DIR)/src/libluajit.a

CXXFLAGS = -Wall -O2 -std=c++11 -ILuaBridge/Source/LuaBridge -ILuaBridge/Source -I$(LUAJIT_INC)

# Files to compile
SRC = embed_luabridge_demo.cpp embed_custom_userdata.cpp embed_stack_api.cpp embed_repl_simple.cpp

# Output binaries
BIN1 = demo_luabridge
BIN2 = demo_custom_userdata
BIN3 = demo_stack_api
BIN4 = demo_repl

# Linking libraries (LuaJIT, libdl, libreadline)
LIBS = $(LUAJIT_LIB) -ldl -lreadline

.PHONY: all clean clean-all test check

# Targets
all: $(LUAJIT_LIB) $(BIN1) $(BIN2) $(BIN3) $(BIN4)

test: $(LUAJIT_LIB)
	$(LUAJIT_DIR)/src/luajit test_ffi_duplicates.lua
	$(LUAJIT_DIR)/src/luajit test_ffi_duplicates_tui.lua
	$(LUAJIT_DIR)/src/luajit test_gallery_portrait.lua
	$(LUAJIT_DIR)/src/luajit test_pix.lua
	$(LUAJIT_DIR)/src/luajit test_ffi_3d_viewer.lua
	$(LUAJIT_DIR)/src/luajit test_ffi_fractal_explorer.lua
	$(LUAJIT_DIR)/src/luajit test_ffi_image_filter_studio.lua
	$(LUAJIT_DIR)/src/luajit test_ffi_system_info.lua
	$(LUAJIT_DIR)/src/luajit test_ffi_verlet_cloth.lua
	$(LUAJIT_DIR)/src/luajit test_ffi_dict.lua
	luajit test_lan_dashboard.lua
	-$(LUAJIT_DIR)/src/luajit test_ffi_suite.lua

# Self-contained Python suites (terminal/PTY, deploy, local servers). The browser/Node UI
# tests (*.js, test_mdview_browser.py) need extra tooling and are not included.
LUAJIT ?= luajit
PY_SUITES = test_hwinfo_tui_pty.py test_termkit_pty.py test_luatop_pty.py \
    test_deploy_dependencies.py test_deploy_mdview.py test_battery_pty.py \
    test_ffi_duplicates_tui_pty.py test_mdview_pty.py test_lazygit_lite.py \
    test_lan_dashboard_scan.py test_landrop_web_http.py

# Run every Lua suite (run_all_tests.lua) and every Python suite; keep going after a
# failure and exit non-zero if anything failed. Uses `luajit` from PATH (LUAJIT=... to override).
check:
	@failed=""; \
	$(LUAJIT) run_all_tests.lua || failed="$$failed run_all_tests.lua"; \
	for suite in $(PY_SUITES); do \
		echo "=== $$suite"; \
		python3 $$suite || failed="$$failed $$suite"; \
	done; \
	echo; \
	if [ -n "$$failed" ]; then echo "FAILED:$$failed"; exit 1; fi; \
	echo "ALL SUITES PASSED"

$(LUAJIT_LIB):
	$(MAKE) -C $(LUAJIT_DIR)

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
	rm -f $(BIN1) $(BIN2) $(BIN3) $(BIN4) *.o

clean-all: clean
	$(MAKE) -C $(LUAJIT_DIR) clean
