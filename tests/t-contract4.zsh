#!/usr/bin/env zunit
#{{{                    MARK:Header
##### Purpose: fasd-simple — fourth-tier contracts.
#####          Pins for `fasd --init auto` shell-dispatch ordering:
#####          zsh checked first, then bash, then POSIX fallback;
#####          plugin entrypoint's PATH-prepend fallback when system
#####          fasd is absent; cache-staleness detection via -nt.
#}}}***********************************************************

@setup {
    0="${${0:#$ZSH_ARGZERO}:-${(%):-%N}}"
    0="${${(M)0:#/*}:-$PWD/$0}"
    pluginDir="${0:h:A}"
    binFile="$pluginDir/bin/fasd"
    pluginFile="$pluginDir/fasd-simple.plugin.zsh"
}

@test '--init auto dispatch checks ZSH_VERSION before BASH_VERSION before POSIX' {
    # Pin: ordering matters because compctl-test is more restrictive
    # than complete-test; running bash dispatch under zsh would skip
    # the zsh-ccomp/zsh-wcomp hooks. Verify the if/elif/else line order.
    local zsh_line bash_line posix_line
    zsh_line=$(grep -nE 'ZSH_VERSION.{0,30}compctl' "$binFile" | head -1 | cut -d: -f1)
    bash_line=$(grep -nE 'BASH_VERSION.{0,30}complete' "$binFile" | head -1 | cut -d: -f1)
    posix_line=$(grep -nF 'else # posix shell' "$binFile" | head -1 | cut -d: -f1)
    [[ -n "$zsh_line" && -n "$bash_line" && -n "$posix_line" ]]
    local ok=$?
    [[ "$zsh_line" -lt "$bash_line" && "$bash_line" -lt "$posix_line" ]]
    local order=$?
    assert $(( ok + order )) equals 0
}

@test 'plugin entrypoint prepends bundled bin/ to PATH when system fasd absent' {
    # Pin: `else` branch of `if [ $commands[fasd] ]` adds the plugin's
    # own bin/ to PATH. Dropping this fallback would silently leave
    # fasd unavailable on systems without a pre-installed fasd binary.
    grep -qE 'export PATH="\$PATH:\$\{0:h\}/bin"' "$pluginFile"
    assert $? equals 0
}

@test 'cache invalidation uses `-nt` (newer-than) on fasd binary vs cache file' {
    # Pin: `[ "$(command -v fasd)" -nt "$fasd_cache" -o ! -s "$fasd_cache" ]`.
    # The -nt operator compares mtimes; dropping it means upgrades to
    # the fasd binary never refresh the init cache, so feature additions
    # in newer versions are invisible.
    grep -qE '"\$\(command -v fasd\)" -nt "\$fasd_cache"' "$pluginFile"
    assert $? equals 0
}

@test 'auto-init zsh branch wires posix-alias AND zsh-hook AND zsh-ccomp' {
    # Pin: zsh dispatch enables posix-alias (the fasd_cd / a / s / d /
    # f / z / zz aliases), zsh-hook (preexec tracking), AND zsh-ccomp
    # (command-mode completion). Dropping any one silently regresses a
    # core feature. Pin presence of each as init-arg keyword.
    awk '/ZSH_VERSION.*compctl/,/elif/' "$binFile" > /tmp/fasd_zb.$$
    local has_alias has_hook has_ccomp
    grep -qF 'posix-alias' /tmp/fasd_zb.$$ && has_alias=0 || has_alias=1
    grep -qF 'zsh-hook' /tmp/fasd_zb.$$ && has_hook=0 || has_hook=1
    grep -qF 'zsh-ccomp' /tmp/fasd_zb.$$ && has_ccomp=0 || has_ccomp=1
    rm -f /tmp/fasd_zb.$$
    assert $(( has_alias + has_hook + has_ccomp )) equals 0
}

@test 'awk-preference search ordering: mawk before gawk before original-awk' {
    # Pin: `for awk in mawk gawk original-awk nawk awk; do`. mawk is
    # the fastest, gawk has GNU extensions, original-awk is the BSD
    # heritage one. Reordering would silently shift `_FASD_AWK` and
    # could break embedded scripts that rely on a specific awk dialect.
    grep -qF 'for awk in mawk gawk original-awk nawk awk' "$binFile"
    assert $? equals 0
}
