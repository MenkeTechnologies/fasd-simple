#!/usr/bin/env zunit
#{{{                    MARK:Header
##### Purpose: fasd-simple — behavioral pins for the two string-munging
#####          subcommands that actually transform user input:
#####            `fasd --sanitize`  (shell-metacharacter neutralization)
#####            `fasd --query`     (BRE construction + literal matching)
#####
#####          These are NOT grep-the-source contract pins. Each test
#####          drives bin/fasd as a subprocess with adversarial input
#####          (command substitution, backticks, regex metacharacters in
#####          a real path) and asserts on the produced OUTPUT / matched
#####          rows, so a re-vendor or refactor that changes the actual
#####          transformation is caught even if the source text matches.
#}}}***********************************************************

@setup {
    0="${${0:#$ZSH_ARGZERO}:-${(%):-%N}}"
    0="${${(M)0:#/*}:-$PWD/$0}"
    pluginDir="${0:h:A}"
    binFile="$pluginDir/bin/fasd"
}

@test '--sanitize strips command substitution so --proc cannot eval injected code' {
    # The fasd preexec/prompt hooks build a command line and feed it
    # through `fasd --sanitize` before `eval "fasd --proc ..."`. If a
    # `$(...)` survives sanitization it would be executed when the hook
    # evaluates the processed line. Pin that command substitution is
    # neutralized: the literal `$(` token must NOT appear in the output.
    #
    # Bug class: command-injection neutralization (the security reason
    # --sanitize exists at all). A naive `tr -d` of metachars that left
    # the parens/contents intact would still let `pwd` reach the eval.
    local out
    out=$(sh "$binFile" --sanitize 'cd $(touch /tmp/fasd_pwned)')
    # The command-substitution opener must be gone.
    assert "$out" does_not_contain '$('
    # And the inner command word must not be carried through verbatim as
    # an executable token followed by its argument list.
    assert "$out" does_not_contain 'touch /tmp/fasd_pwned'
}

@test '--sanitize collapses pipe/redirect/semicolon metachars but keeps a plain path' {
    # Bug class: over- vs under-stripping. The sed class is
    # `[|&;<>$\`{}]` -> space. A path with spaces must survive intact
    # (the field separator fasd cares about is `|`, not space), while a
    # pipeline-with-redirect must have its operators removed so the
    # recorded "command" is just the bare words.
    local plain meta
    plain=$(sh "$binFile" --sanitize 'vim /tmp/my report.txt')
    # A legitimate spaced path is preserved verbatim - spaces are NOT
    # in the metachar class, so munging it would be a regression.
    assert "$plain" same_as 'vim /tmp/my report.txt'

    meta=$(sh "$binFile" --sanitize 'ls | grep foo > out')
    # Operators must be gone...
    assert "$meta" does_not_contain '|'
    assert "$meta" does_not_contain '>'
    # ...but the surrounding command words must remain.
    assert "$meta" contains 'ls'
    assert "$meta" contains 'grep foo'
    assert "$meta" contains 'out'
}

@test '--query escapes "." in the query so it matches literally, not as any-char' {
    # --query builds a BRE from the user query and pre-escapes
    # `* . \ [` via sed (`s/\([*\.\\\[]\)/\\\1/g`). If that escaping
    # regresses, a `.` in the query degrades to regex "any char".
    #
    # Bug class: regex-metacharacter escaping / false-positive match.
    # Discrimination: seed TWO rows that differ ONLY at the dot
    # position - `data.log` vs `dataXlog`. Querying `data.log` must
    # return the dotted row and NOT the `X` row; an unescaped `.`
    # would match BOTH (`.` matches the `X`). Default FUZZY (2) is
    # used so the exact-BRE path - not a fuzzy fallback - decides.
    local dir db out
    dir=$(mktemp -d "${TMPDIR:-/tmp}/fasd_q.XXXXXX")
    mkdir -p "$dir/data.log" "$dir/dataXlog"
    db="$dir/.fasd"
    local now; now=$(date +%s)
    # Seed rows directly: avoids fasd's first-run awk-missing-file
    # quirk and pins ONLY the --query matching logic under test.
    print -r -- "$dir/data.log|1|$now"  > "$db"
    print -r -- "$dir/dataXlog|1|$now" >> "$db"

    out=$(_FASD_DATA="$db" _FASD_SINK=/dev/null _FASD_BACKENDS=native \
        _FASD_AWK=awk _FASD_FUZZY=2 sh "$binFile" --query d 'data.log')
    assert "$out" contains "$dir/data.log"
    # The decisive assertion: the `X` row must be absent. Its presence
    # would prove `.` leaked through as a live regex metacharacter.
    assert "$out" does_not_contain 'dataXlog'

    command rm -rf "$dir"
}

@test '--query escapes "[" in the query so a bracket matches literally, not a class' {
    # Companion to the `.` test for the OTHER escaped metacharacter,
    # `[`. Seed `log[1]` and `log1`. A correctly-escaped query
    # `log[1]` matches only the bracketed row; an unescaped `[1]`
    # is a one-char class matching `1`, which would wrongly also
    # match `log1`.
    #
    # Bug class: bracket-expression escaping / false-positive match.
    local dir db out
    dir=$(mktemp -d "${TMPDIR:-/tmp}/fasd_q.XXXXXX")
    mkdir -p "$dir/log[1]" "$dir/log1"
    db="$dir/.fasd"
    local now; now=$(date +%s)
    print -r -- "$dir/log[1]|1|$now"  > "$db"
    print -r -- "$dir/log1|1|$now"   >> "$db"

    out=$(_FASD_DATA="$db" _FASD_SINK=/dev/null _FASD_BACKENDS=native \
        _FASD_AWK=awk _FASD_FUZZY=2 sh "$binFile" --query d 'log[1]')
    assert "$out" contains "$dir/log[1]"
    # `log1` must NOT appear - its presence proves `[1]` was treated
    # as a regex character class rather than two literal characters.
    # (`log1` is not a substring of `log[1]`, so this is unambiguous.)
    assert "$out" does_not_contain "$dir/log1"

    command rm -rf "$dir"
}
