-- Luacheck configuration for the repository.
-- Catches leaked globals, undefined names, unused variables and shadowing.
-- See AGENTS.md "Static Analysis (luacheck)" for how it is used.

std = "luajit"

-- Line length is enforced only on added lines by the diff check in
-- AGENTS.md, so long lines in untouched legacy code are not reported here.
max_line_length = false

-- Methods defined with ':' often do not use self; that is not a bug.
self = false

-- Vendored git submodules are not ours to lint.
exclude_files = {
    "LuaJIT/**",
    "LuaBridge/**",
}
