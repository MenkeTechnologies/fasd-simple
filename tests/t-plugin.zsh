#!/usr/bin/env zunit
#{{{                    MARK:Header
#**************************************************************
##### Purpose: fasd-simple.plugin.zsh contract pins.
#####          - cache lives under $ZSH_CACHE_DIR
#####          - vendored bin/fasd is used as a fallback when
#####            no system `fasd` exists on PATH
#####          - sourcing installs `fasd_cd` + `_fasd_preexec`
#####          - `fasd_cache` is not leaked into the env
#}}}***********************************************************

@setup {
    0="${${0:#$ZSH_ARGZERO}:-${(%):-%N}}"
    0="${${(M)0:#/*}:-$PWD/$0}"
    pluginDir="${0:h:A}"
}

@test 'plugin file gates everything on $commands[fasd]' {
    # Contract: the entry guard must inspect $commands[fasd] so the plugin
    # does the right thing on hosts both with and without a system fasd.
    local body
    body=$(cat "$pluginDir/fasd-simple.plugin.zsh")
    assert "$body" contains '$commands[fasd]'
}

@test 'plugin file writes its init cache under $ZSH_CACHE_DIR' {
    # Pin: cache location must be ${ZSH_CACHE_DIR}/fasd-init-cache.
    # If a refactor inlines the cache into the plugin dir, plugin updates
    # would silently break on read-only repo checkouts.
    local body
    body=$(cat "$pluginDir/fasd-simple.plugin.zsh")
    assert "$body" contains '${ZSH_CACHE_DIR}/fasd-init-cache'
}

@test 'plugin file regenerates cache when the fasd binary is newer' {
    # The `-nt` test is the only thing keeping users on a stale init
    # snippet after they upgrade fasd. Pin it.
    local body
    body=$(cat "$pluginDir/fasd-simple.plugin.zsh")
    assert "$body" contains '-nt'
    assert "$body" contains 'fasd --init auto'
}

@test 'plugin file falls back to vendored bin/fasd when system fasd absent' {
    # Without this branch the plugin would silently no-op on bare hosts.
    local body
    body=$(cat "$pluginDir/fasd-simple.plugin.zsh")
    assert "$body" contains '${0:h}/bin'
    assert "$body" contains 'export PATH'
}

@test 'plugin file unsets fasd_cache after sourcing (no env leak)' {
    # Pin: the variable used to build the cache path must be cleaned up
    # so it does not leak into the user's interactive shell.
    local body
    body=$(cat "$pluginDir/fasd-simple.plugin.zsh")
    local count
    count=$(printf '%s\n' "$body" | grep -c 'unset fasd_cache')
    assert "$count" same_as '2'
}

@test 'plugin file is short — under 30 lines (no scope creep)' {
    # The whole plugin is meant to be a 17-line bootstrap. If it grows
    # past 30 lines somebody is probably putting business logic into the
    # entry point — that should live in bin/ or a sourced helper.
    local lines
    lines=$(wc -l < "$pluginDir/fasd-simple.plugin.zsh" | tr -d ' ')
    local result=$([[ "$lines" -le 30 ]] && echo yes || echo "no:$lines")
    assert "$result" same_as 'yes'
}

@test 'vendored bin/fasd exists and is executable' {
    # Pin: the vendored shell script must be present and `+x` so the
    # fallback branch works after a fresh clone.
    assert "$pluginDir/bin/fasd" is_file
    [[ -x "$pluginDir/bin/fasd" ]]
    assert $? equals 0
}

@test 'vendored bin/fasd identifies itself as a POSIX-compatible shell script' {
    # Pin: shebang must be /usr/bin/env sh so the binary stays portable.
    # Switching to bash would break it on Alpine and similar minimal hosts.
    local first
    first=$(head -1 "$pluginDir/bin/fasd")
    assert "$first" same_as '#!/usr/bin/env sh'
}

@test 'vendored bin/fasd defines the fasd() function' {
    # Pin: bin/fasd MUST define `fasd()` — that is the entire public
    # interface. The plugin sources `fasd --init auto`, but the binary
    # itself is what defines the function once on PATH.
    local body
    body=$(cat "$pluginDir/bin/fasd")
    assert "$body" contains 'fasd() {'
}

@test 'sourcing the plugin against vendored bin defines fasd_cd and preexec hook' {
    # End-to-end: prepend the vendored bin so `$commands[fasd]` finds the
    # vendored binary (matches both real-world cases — system fasd present
    # OR fallback). Verify the canonical hook + wrapper that fasd installs.
    local tmp funcs
    tmp=$(mktemp -d)
    funcs=$(ZSH_CACHE_DIR="$tmp" PATH="$pluginDir/bin:$PATH" zsh -c "
        emulate zsh
        autoload -Uz add-zsh-hook
        source '$pluginDir/fasd-simple.plugin.zsh' 2>/dev/null
        typeset -f fasd_cd >/dev/null && print -n 'cd:yes ' || print -n 'cd:no '
        print -n hook:
        print -r -- \${preexec_functions[(r)_fasd_preexec]:-NONE}
    " 2>/dev/null)
    rm -rf "$tmp"
    assert "$funcs" contains 'cd:yes'
    assert "$funcs" contains 'hook:_fasd_preexec'
}

@test 'sourcing the plugin creates the cache file under ZSH_CACHE_DIR' {
    # Pin: after first source, $ZSH_CACHE_DIR/fasd-init-cache must exist
    # and be non-empty (`>|` truncate-and-write would otherwise leave a
    # 0-byte file on a broken init).
    local tmp
    tmp=$(mktemp -d)
    ZSH_CACHE_DIR="$tmp" PATH="$pluginDir/bin:$PATH" zsh -c "
        emulate zsh
        autoload -Uz add-zsh-hook
        source '$pluginDir/fasd-simple.plugin.zsh' 2>/dev/null
    " >/dev/null 2>&1
    assert "$tmp/fasd-init-cache" is_file
    local size
    size=$(wc -c < "$tmp/fasd-init-cache" | tr -d ' ')
    local result=$([[ "$size" -gt 0 ]] && echo yes || echo "no:$size")
    rm -rf "$tmp"
    assert "$result" same_as 'yes'
}

@test 'sourcing the plugin does not leak $fasd_cache into the environment' {
    # Pin: both branches of the plugin must `unset fasd_cache`.
    local tmp leaked
    tmp=$(mktemp -d)
    leaked=$(ZSH_CACHE_DIR="$tmp" PATH="$pluginDir/bin:$PATH" zsh -c "
        emulate zsh
        autoload -Uz add-zsh-hook
        source '$pluginDir/fasd-simple.plugin.zsh' 2>/dev/null
        print \${fasd_cache-UNSET}
    " 2>/dev/null)
    rm -rf "$tmp"
    assert "$leaked" same_as 'UNSET'
}

@test 're-sourcing the plugin is idempotent — cache file content matches' {
    # Pin: sourcing twice must leave the cache identical. The `-nt` check
    # decides whether to regenerate — if the binary isn't newer than the
    # cache, the regen should be skipped.
    local tmp a b
    tmp=$(mktemp -d)
    ZSH_CACHE_DIR="$tmp" PATH="$pluginDir/bin:$PATH" zsh -c "
        emulate zsh
        autoload -Uz add-zsh-hook
        source '$pluginDir/fasd-simple.plugin.zsh'
    " >/dev/null 2>&1
    a=$(md5 -q "$tmp/fasd-init-cache" 2>/dev/null || md5sum "$tmp/fasd-init-cache" | awk '{print $1}')
    ZSH_CACHE_DIR="$tmp" PATH="$pluginDir/bin:$PATH" zsh -c "
        emulate zsh
        autoload -Uz add-zsh-hook
        source '$pluginDir/fasd-simple.plugin.zsh'
    " >/dev/null 2>&1
    b=$(md5 -q "$tmp/fasd-init-cache" 2>/dev/null || md5sum "$tmp/fasd-init-cache" | awk '{print $1}')
    rm -rf "$tmp"
    assert "$a" same_as "$b"
}

@test 'bin/fasd --init posix-alias emits fasd_cd() (the canonical wrapper)' {
    # Sanity that the vendored binary's init output still contains the
    # documented fasd_cd wrapper users rely on for `z` / `zz`-style aliases.
    local out
    out=$("$pluginDir/bin/fasd" --init posix-alias 2>/dev/null)
    assert "$out" contains 'fasd_cd()'
    assert "$out" contains 'fasd -e'
}
