# SPDX-License-Identifier: MIT
# dsl/desugar_pipe.awk -- pipe operator (|>) transform
#
# expr |> f()        → _ds_p_N = f(expr);      line gets _ds_p_N
# expr |> f(a, b)    → _ds_p_N = f(expr, a,b); line gets _ds_p_N
# Chains processed left-to-right iteratively.

# Find position of closing ) matching the ( at open_pos in s (1-indexed)
function _ds_pipe_find_close(s, open_pos,    i, c, depth) {
    depth = 1; i = open_pos + 1
    while (i <= length(s) && depth > 0) {
        c = substr(s, i, 1)
        if      (c == "(") depth++
        else if (c == ")") depth--
        i++
    }
    return i - 1
}

# Find where the left operand token starts (scan left from pipe_pos-1).
# NOTE: only handles simple identifier LHS (variable names, temp vars like _ds_p_1).
# Complex expressions (function calls, array subscripts, parenthesized exprs)
# on the LHS of |> are not supported — use a let binding first:
#   let tmp = foo(x)
#   let result = tmp |> trim()
function _ds_pipe_left_start(masked, pipe_pos,    i) {
    i = pipe_pos - 1
    while (i >= 1 && substr(masked, i, 1) == " ") i--
    while (i > 1 && substr(masked, i - 1, 1) ~ /[a-zA-Z0-9_]/) i--
    return i
}

function _ds_pipe_transform(line, pre_buf,    segs, n, masked, pipe_pos, m,
    left_start, left_op, rhs, fname, open_pos, close_pos, fargs, tmpvar, pb,
    rhs_abs_end, indent, left_type, cls) {
    delete pre_buf
    pb = 0

    n      = _ds_split_code_segs(line, segs)
    masked = _ds_nc_mask(segs, n)

    indent = ""
    if (match(line, /^[[:space:]]*/)) indent = substr(line, 1, RLENGTH)

    while (match(masked, /\|>/)) {
        pipe_pos = RSTART

        left_start = _ds_pipe_left_start(masked, pipe_pos)
        left_op    = _ds_trim(substr(line, left_start, pipe_pos - left_start))

        # Sealed-pipe check: Result/Option cannot be piped directly
        left_type = _ds_infer_type(left_op)
        # If the type cannot be inferred from the expression, try looking it up as a variable
        if (left_type == "" && _DS_in_function) {
            if ((_DS_func_name, left_op) in _DS_VAR_TYPES) {
                left_type = _DS_VAR_TYPES[_DS_func_name, left_op]
            }
        }
        if (_ds_is_nullable(left_type)) {
            print "dsl error: " _DS_src_file ":" _DS_current_lineno \
                ": pipe input is " left_type " — use ?= or match to unwrap first" > "/dev/stderr"
            _DS_had_error = 1
            return line
        }

        rhs = substr(line, pipe_pos + 2)
        if (!match(rhs, /^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)*)[[:space:]]*\(/, m))
            return line

        fname     = m[1]
        open_pos  = index(rhs, "(")
        close_pos = _ds_pipe_find_close(rhs, open_pos)
        fargs     = _ds_trim(substr(rhs, open_pos + 1, close_pos - open_pos - 1))

        # Untrusted-propagation check: classify:transform, classify:validator, classify:sanitizer accept Untrusted input
        if (_ds_is_untrusted(left_type)) {
            cls = _DS_FUNC_CLASS[fname]
            if (cls != "transform" && cls != "validator" && cls != "sanitizer") {
                print "dsl error: " _DS_src_file ":" _DS_current_lineno \
                    ": " fname " does not accept Untrusted input — classify as transform or unwrap first" > "/dev/stderr"
                _DS_had_error = 1
                return line
            }
        }

        rhs_abs_end = (pipe_pos + 2 - 1) + close_pos

        _DS_pipe_count++
        tmpvar = "_ds_p_" _DS_pipe_count
        if (_DS_in_function) _DS_let_locals[++_DS_let_count] = tmpvar

        if (fargs == "")
            pre_buf[++pb] = indent tmpvar " = " fname "(" left_op ")"
        else
            pre_buf[++pb] = indent tmpvar " = " fname "(" left_op ", " fargs ")"

        # Track propagated type for this temp var (using dataflow to preserve Untrusted<T>)
        if (_DS_in_function) {
            _DS_VAR_TYPES[_DS_func_name, tmpvar] = _ds_dataflow_ret(fname, left_type)
        }

        line = substr(line, 1, left_start - 1) tmpvar substr(line, rhs_abs_end + 1)

        n      = _ds_split_code_segs(line, segs)
        masked = _ds_nc_mask(segs, n)
    }
    return line
}
