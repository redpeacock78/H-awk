# SPDX-License-Identifier: MIT
# core/type.awk -- DSL型アノテーション用ランタイム変換
@namespace "type"

function coerce(val, typename) {
    if (typename == "Int") {
        if (val !~ /^-?[0-9]+$/) {
            print "type error: cannot coerce \"" val "\" to Int" > "/dev/stderr"
            exit 1
        }
        return int(val)
    }
    if (typename == "Float") {
        if (val !~ /^-?[0-9]*\.?[0-9]+([eE][+-]?[0-9]+)?$/) {
            print "type error: cannot coerce \"" val "\" to Float" > "/dev/stderr"
            exit 1
        }
        return val + 0
    }
    if (typename == "Str") {
        return val ""
    }
    if (typename == "Bool") {
        if (val == "true"  || val == "1") return 1
        if (val == "false" || val == "0" || val == "") return 0
        print "type error: cannot coerce \"" val "\" to Bool" > "/dev/stderr"
        exit 1
    }
    print "type::coerce: unknown type: " typename > "/dev/stderr"
    exit 1
}

@namespace "awk"
