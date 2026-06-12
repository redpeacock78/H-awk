# SPDX-License-Identifier: MIT
# dsl/desugar_nullcoalesce.awk -- ?? null-coalescing operator transform
#
# expr ?? default  →  temp = expr (emitted as pre-line)
#                      (temp != "" ? temp : default)  (replaces expr ?? default)
#
# Works anywhere in a line (function args, let RHS, standalone expressions).
# String/comment regions are masked so ?? inside literals is not transformed.
# Temp vars (_ds_tc_N) are registered as function locals when inside a function.

# _ds_nc_mask: replace safe=0 segment chars with 'x' (same length, for position math)
function _ds_nc_mask(segs, n,    result, i, pad) {
    result = ""
    for (i = 1; i <= n; i++) {
        if (segs[i, "safe"]) {
            result = result segs[i, "text"]
        } else {
            pad = segs[i, "text"]
            gsub(/./, "x", pad)
            result = result pad
        }
    }
    return result
}

# _ds_nc_left_bound: scan left from pos, return position of delimiter (, = () or 0
function _ds_nc_left_bound(masked, pos,    i, c, depth) {
    depth = 0
    for (i = pos; i >= 1; i--) {
        c = substr(masked, i, 1)
        if      (c == ")")                         { depth++ }
        else if (c == "(")  { if (depth == 0) return i; depth-- }
        else if ((c == "," || c == "=") && depth == 0) { return i }
    }
    return 0
}

# _ds_nc_right_bound: scan right from pos, return position of delimiter () ,) or len+1
function _ds_nc_right_bound(masked, pos, mlen,    i, c, depth) {
    depth = 0
    for (i = pos; i <= mlen; i++) {
        c = substr(masked, i, 1)
        if      (c == "(")               { depth++ }
        else if (c == ")") { if (depth == 0) return i; depth-- }
        else if (c == "," && depth == 0) { return i }
    }
    return mlen + 1
}

function _ds_trim(s) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    return s
}

# _ds_nc_transform: transform first ?? in line.
# Fills pre_buf[1] with temp var assignment if ?? is found.
# Returns modified line (with ?? replaced by ternary).
# Returns original line unchanged if no ?? found.
function _ds_nc_transform(line, pre_buf,    segs, n, masked, qpos,
    lb, rb, mlen, expr, dflt, tmpvar, lpart, rpart, indent, sep) {
    delete pre_buf
    n = _ds_split_code_segs(line, segs)
    masked = _ds_nc_mask(segs, n)
    mlen = length(masked)

    if (!match(masked, /\?\?/)) return line

    qpos = RSTART  # 1-indexed position of first ?

    # Find indentation (for pre-line)
    indent = ""
    if (match(line, /^[[:space:]]*/)) indent = substr(line, 1, RLENGTH)

    # Left boundary: scan from qpos-1 leftward
    lb = _ds_nc_left_bound(masked, qpos - 1)

    # Right boundary: scan from qpos+2 rightward (after ??)
    rb = _ds_nc_right_bound(masked, qpos + 2, mlen)

    # Extract EXPR: from lb+1 to qpos-1 (trimmed)
    expr = _ds_trim(substr(line, lb + 1, qpos - lb - 1))

    # Extract DEFAULT: from qpos+2 to rb-1 (trimmed)
    dflt = _ds_trim(substr(line, qpos + 2, rb - qpos - 2))

    # Generate temp var name
    _DS_tc_count++
    tmpvar = "_ds_tc_" _DS_tc_count

    # Register as function local (for hoisting) when inside a function body
    if (_DS_in_function) _DS_let_locals[++_DS_let_count] = tmpvar

    # Build pre-line: temp var assignment
    pre_buf[1] = indent tmpvar " = " expr

    # Build modified line: replace "lb_delimiter EXPR ?? DEFAULT" with ternary
    lpart = substr(line, 1, lb)       # up to and including left delimiter
    rpart = substr(line, rb)          # from right delimiter to end

    # sep: add space after delimiter (,/=/() when lb>0; no space when EXPR at line start
    sep = (lb > 0 ? " " : "")
    return lpart sep "(" tmpvar " != \"\" ? " tmpvar " : " dflt ")" rpart
}
