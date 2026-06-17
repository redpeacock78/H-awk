# SPDX-License-Identifier: MIT
# dsl/type.awk -- DSL 型アノテーション用ランタイム変換
#
# type::coerce(val, typename)  -- ランタイム型変換（デシュガー出力から呼ばれる）
# _DS_SIG_RET[]                -- 既知 DSL 関数の戻り型（dsl/sig.awk で定義）

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
        if (val == "true" || val == "1") return 1
        if (val == "false" || val == "0" || val == "") return 0
        print "type error: cannot coerce \"" val "\" to Bool" > "/dev/stderr"
        exit 1
    }

    print "type::coerce: unknown type: " typename > "/dev/stderr"
    exit 1
}

# type::split_union -- split at top-level | only (respects <...> depth)
# stores results in out[], returns count
function split_union(t, out,    i, c, depth, cur, n) {
    n = 0; depth = 0; cur = ""
    for (i = 1; i <= length(t); i++) {
        c = substr(t, i, 1)
        if      (c == "<") depth++
        else if (c == ">") depth--
        else if (c == "|" && depth == 0) {
            out[++n] = _ds_trim_type(cur)
            cur = ""
            continue
        }
        cur = cur c
    }
    if (length(_ds_trim_type(cur)) > 0) out[++n] = _ds_trim_type(cur)
    return n
}

function _ds_trim_type(s) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    return s
}

# type::split_intersection -- split at top-level & only (respects <...> depth)
# stores results in out[], returns count
function split_intersection(t, out,    i, c, depth, cur, n) {
    n = 0; depth = 0; cur = ""
    for (i = 1; i <= length(t); i++) {
        c = substr(t, i, 1)
        if      (c == "<") depth++
        else if (c == ">") depth--
        else if (c == "&" && depth == 0) {
            out[++n] = _ds_trim_type(cur)
            cur = ""
            continue
        }
        cur = cur c
    }
    if (length(_ds_trim_type(cur)) > 0) out[++n] = _ds_trim_type(cur)
    return n
}

# type::is_union -- returns 1 if t is a Union type
function is_union(t,    out, n) {
    n = split_union(t, out)
    return (n > 1)
}

# type::normalize -- sort members, deduplicate, join with | or & (no spaces)
function normalize(t,    out, n, i, j, sorted, seen, result, tmp, sep) {
    # try | (union) first
    n = split_union(t, out)
    sep = "|"
    if (n == 1) {
        # try & (intersection)
        n = split_intersection(t, out)
        sep = "&"
    }
    if (n == 1) return expand_alias(out[1])
    # deduplicate
    for (i = 1; i <= n; i++) seen[expand_alias(out[i])] = 1
    n = 0
    for (i in seen) sorted[++n] = i
    # bubble sort (small n)
    for (i = 1; i <= n; i++)
        for (j = i+1; j <= n; j++)
            if (sorted[i] > sorted[j]) { tmp = sorted[i]; sorted[i] = sorted[j]; sorted[j] = tmp }
    result = sorted[1]
    for (i = 2; i <= n; i++) result = result sep sorted[i]
    return result
}

# type::union_of -- combine two types into a normalized union
function union_of(a, b) {
    if (a == "" || a == "Any") return b
    if (b == "" || b == "Any") return a
    if (a == b) return a
    return normalize(a "|" b)
}

# type::expand_alias -- expand alias if found in _DS_TYPE_ALIAS, else return as-is
function expand_alias(t) {
    if (t in awk::_DS_TYPE_ALIAS) return awk::_DS_TYPE_ALIAS[t]
    return t
}

# type::accepts -- returns 1 if expected accepts actual, 0 if not
function accepts(expected, actual,    eparts, apart, en, an, i, j, einter, ei_n, _eg, _ag) {
    if (expected == actual)  return 1
    if (expected == "Any")   return 1
    if (actual   == "Any")   return 1
    if (actual   == "")      return 1

    # aliases must not be circular (table is hardcoded in sig.awk)
    if (expected in awk::_DS_TYPE_ALIAS) return accepts(awk::_DS_TYPE_ALIAS[expected], actual)
    if (actual   in awk::_DS_TYPE_ALIAS) return accepts(expected, awk::_DS_TYPE_ALIAS[actual])

    # intersection in expected: actual must satisfy ALL members
    ei_n = split_intersection(expected, einter)
    if (ei_n > 1) {
        for (i = 1; i <= ei_n; i++)
            if (!accepts(einter[i], actual)) return 0
        return 1
    }

    # covariant generic types: Option<T> accepts Option<U> if T accepts U
    if (match(expected, /^([A-Za-z_][A-Za-z0-9_]*)<(.+)>$/, _eg) && \
        match(actual,   /^([A-Za-z_][A-Za-z0-9_]*)<(.+)>$/, _ag)) {
        if (_eg[1] == _ag[1]) return accepts(_eg[2], _ag[2])
    }

    en = split_union(expected, eparts)
    an = split_union(actual,   apart)

    if (en > 1 && an == 1) {
        # expected is union: any member accepts actual => OK
        for (i = 1; i <= en; i++)
            if (accepts(eparts[i], actual)) return 1
        return 0
    }

    if (an > 1) {
        # actual is union: ALL members must be accepted by expected
        for (j = 1; j <= an; j++)
            if (!accepts(expected, apart[j])) return 0
        return 1
    }

    return 0
}

