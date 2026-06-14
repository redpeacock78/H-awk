# SPDX-License-Identifier: MIT
# dsl/desugar_match.awk -- match...of...end expression transform
#
# Syntax:
#   match EXPR of
#     ok VAR:       -- Result ok branch (binds VAR to result_val)
#     ng VAR:       -- Result error branch (binds VAR to result_err)
#     some VAR:     -- Option some branch (binds VAR to option_val)
#     none:         -- Option none branch (no binding)
#     default:      -- catch-all (no binding; replaces ng/none)
#   end
#
# Desugars to: tmpvar = EXPR; if (...) { ... } else { ... }

# Returns 1 if the line starts a match block; captures indent in m[1], expr in m[2]
function _ds_match_starts(line, m) {
    return match(line, /^([[:space:]]*)match[[:space:]]+(.+)[[:space:]]+of[[:space:]]*$/, m)
}

# Collect a line while inside a match block. Returns "" always.
# Branch headers set state; body lines are buffered; "end" triggers emit.
function _ds_match_collect(line, lineno,    m) {
    if (match(line, /^[[:space:]]*ok[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
        _DS_match_ok_var = m[1]; _DS_match_branch = "ok"; return ""
    }
    if (match(line, /^[[:space:]]*ng[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
        _DS_match_ng_var = m[1]; _DS_match_branch = "ng"; _DS_match_has_ng = 1; return ""
    }
    if (match(line, /^[[:space:]]*some[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
        _DS_match_ok_var = m[1]; _DS_match_branch = "some"; return ""
    }
    if (line ~ /^[[:space:]]*none:[[:space:]]*$/) {
        _DS_match_branch = "none"; _DS_match_has_ng = 1; return ""
    }
    if (line ~ /^[[:space:]]*default:[[:space:]]*$/) {
        _DS_match_branch = "default"; _DS_match_has_ng = 1; return ""
    }
    if (line ~ /^[[:space:]]*end[[:space:]]*$/) {
        _DS_in_match = 0; _ds_match_emit(lineno); return ""
    }
    # Body line — buffer under current branch
    if (_DS_match_branch == "ok" || _DS_match_branch == "some")
        _DS_match_ok_body[++_DS_match_ok_count] = line
    else
        _DS_match_ng_body[++_DS_match_ng_count] = line
    return ""
}

# Emit desugared if/else into _DS_body_buf.
function _ds_match_emit(lineno,    tmpvar, type_t, check_fn, val_fn, err_fn, i) {
    if (!_DS_match_has_ng) {
        print "dsl error: " _DS_src_file ":" lineno \
            ": match block missing ng/none/default branch" > "/dev/stderr"
        _DS_had_error = 1
        _DS_match_ok_count = 0; _DS_match_ng_count = 0
        _DS_match_ok_var = ""; _DS_match_ng_var = ""
        _DS_match_has_ng = 0; _DS_match_branch = ""
        _DS_match_expr = ""; _DS_match_indent = ""
        delete _DS_match_ok_body; delete _DS_match_ng_body
        return
    }

    _DS_mc_count++
    tmpvar = "_ds_mc_" _DS_mc_count
    if (_DS_in_function) {
        _DS_let_locals[++_DS_let_count] = tmpvar
        if (_DS_match_ok_var != "") _DS_let_locals[++_DS_let_count] = _DS_match_ok_var
        if (_DS_match_ng_var != "") _DS_let_locals[++_DS_let_count] = _DS_match_ng_var
    }

    type_t = _ds_infer_type(_DS_match_expr)
    if (type_t ~ /^Option</) {
        check_fn = "option_some"; val_fn = "option_val"; err_fn = ""
    } else {
        check_fn = "result_ok"; val_fn = "result_val"; err_fn = "result_err"
    }

    _DS_body_buf[++_DS_body_count] = _DS_match_indent tmpvar " = " _ds_dot_transform(_DS_match_expr)
    _DS_body_buf[++_DS_body_count] = _DS_match_indent "if (" check_fn "(" tmpvar ")) {"
    if (_DS_match_ok_var != "")
        _DS_body_buf[++_DS_body_count] = _DS_match_indent "  " _DS_match_ok_var " = " val_fn "(" tmpvar ")"
    for (i = 1; i <= _DS_match_ok_count; i++)
        _ds_match_process_body(_DS_match_ok_body[i], lineno)
    _DS_body_buf[++_DS_body_count] = _DS_match_indent "} else {"
    if (_DS_match_ng_var != "" && err_fn != "")
        _DS_body_buf[++_DS_body_count] = _DS_match_indent "  " _DS_match_ng_var " = " err_fn "(" tmpvar ")"
    for (i = 1; i <= _DS_match_ng_count; i++)
        _ds_match_process_body(_DS_match_ng_body[i], lineno)
    _DS_body_buf[++_DS_body_count] = _DS_match_indent "}"

    _DS_match_ok_count = 0; _DS_match_ng_count = 0
    _DS_match_ok_var = ""; _DS_match_ng_var = ""
    _DS_match_has_ng = 0; _DS_match_branch = ""
    _DS_match_expr = ""; _DS_match_indent = ""
    delete _DS_match_ok_body; delete _DS_match_ng_body
}

# Process a collected body line through the full pipeline, push to _DS_body_buf.
function _ds_match_process_body(line, lineno,    pipe_pre, nc_pre, p, pipe_r, dot_r, nc_r, xf) {
    _DS_current_lineno = lineno
    pipe_r = _ds_pipe_transform(line, pipe_pre)
    for (p = 1; p in pipe_pre; p++) _DS_body_buf[++_DS_body_count] = pipe_pre[p]
    dot_r = _ds_dot_transform(pipe_r)
    nc_r  = _ds_nc_transform(dot_r, nc_pre)
    for (p = 1; p in nc_pre; p++) _DS_body_buf[++_DS_body_count] = nc_pre[p]
    _ds_typecheck_plain_call(nc_r)
    _ds_check_return(dot_r, lineno)
    xf = _ds_let_transform(nc_r, lineno, line)
    if (xf != "") _DS_body_buf[++_DS_body_count] = xf
}
