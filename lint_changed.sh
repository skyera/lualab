#!/bin/sh
# Fail if any added or modified Lua file has more luacheck warnings than
# its HEAD version. New files must have zero warnings. Legacy warnings in
# untouched code are tolerated so changes stay surgical (see AGENTS.md).
#
# Exit status: 0 no new warnings, 1 new warnings, 2 setup or luacheck error.

if ! command -v luacheck >/dev/null 2>&1; then
    echo "error: luacheck not found in PATH" >&2
    echo "install: luarocks install luacheck" \
        "(Windows: luacheck.exe from" \
        "https://github.com/lunarmodules/luacheck/releases)" >&2
    exit 2
fi

cd "$(git rev-parse --show-toplevel)" || exit 2

# Print the number of warnings in stdin; exit 2 on a luacheck fatal error.
count_warnings() {
    output=$(luacheck --formatter plain --no-color --filename "$1" -)
    status=$?
    if [ "$status" -ge 3 ]; then
        echo "error: luacheck failed on $1 (exit $status)" >&2
        echo "$output" >&2
        exit 2
    fi
    # grep -c exits 1 when it counts zero lines; zero is a valid result.
    printf '%s\n' "$output" | grep -c . || true
}

list_changed_lua_files() {
    git diff --name-only --diff-filter=AMR HEAD -- '*.lua'
    git ls-files --others --exclude-standard -- '*.lua'
}

failed=0
checked=0
files=$(list_changed_lua_files | sort -u)
# A here-document keeps the loop in this shell (a pipe would run it in a
# subshell and lose the counters) and splits only on newlines.
while IFS= read -r file; do
    if [ -z "$file" ]; then
        continue
    fi
    checked=$((checked + 1))
    # $file is only a --filename label for luacheck; nothing writes to it.
    # shellcheck disable=SC2094
    current=$(count_warnings "$file" < "$file") || exit 2
    if git cat-file -e "HEAD:$file" 2>/dev/null; then
        base=$(git show "HEAD:$file" | count_warnings "$file") || exit 2
    else
        base=0
    fi
    if [ "$current" -gt "$base" ]; then
        echo "FAIL $file: $base -> $current issues"
        luacheck --no-color --codes "$file" | grep -E '^ +'
        failed=1
    else
        echo "ok   $file: $base -> $current issues"
    fi
done <<EOF
$files
EOF

if [ "$checked" -eq 0 ]; then
    echo "lint: no added or modified Lua files"
elif [ "$failed" -ne 0 ]; then
    echo "lint: new luacheck issues; fix them before shipping" >&2
fi
exit "$failed"
