# SPDX-License-Identifier: MIT
# dsl/desugar_match.awk -- when...of...end expression transform
#
# Syntax:
#   when EXPR of
#     ok VAR:           -- Result ok branch (binds VAR to result_val)
#     ok:               -- Result ok branch (no binding)
#     some VAR:         -- Option some branch (binds VAR to option_val)
#     some:             -- Option some branch (no binding)
#     ng VAR<TypeName>: -- typed ng, bind VAR to result_err, match by type
#     ng <TypeName>:    -- typed ng, no bind, match by type
#     ng VAR:           -- untyped ng, bind VAR to result_err
#     ng:               -- untyped ng, no bind
#     none:             -- Option none branch (catch-all for option)
#     default VAR:      -- catch-all, bind VAR to result_err
#     default:          -- catch-all, no binding
#   end
#
# Desugars to: tmpvar = EXPR; if (...) { ... } else if (...) { ... } else { ... }

BEGIN {
  _DS_match_depth = 0
}

# Returns 1 if the line starts a when block; captures indent in m[1], expr in m[2]
function _ds_match_starts(line, m, lineno,    d, k, name) {
  if (match(line, /^([[:space:]]*)when[[:space:]]+(.+)[[:space:]]+of[[:space:]]*$/, m)) {
    d = ++_DS_match_depth
    _DS_in_match = 1
    _DS_match_indent[d] = m[1]
    _DS_match_expr[d] = m[2]
    _DS_match_lineno[d] = (lineno != "" ? lineno : _DS_current_lineno)
    _DS_match_ok_count[d] = 0
    _DS_match_ng_arms[d] = 0
    _DS_match_cur_ng_arm[d] = 0
    _DS_match_branch[d] = ""
    _DS_match_ok_var[d] = ""
    _DS_match_is_option[d] = 0
    _ds_saw_catchall[d] = 0
    delete _DS_match_active_bind[d]
    _ds_match_delete_depth(_DS_match_outer_binds, d)
    for (k = 1; k < d; k++) {
      name = _DS_match_active_bind[k]
      if (name != "") _DS_match_outer_binds[d, name] = 1
    }
    return 1
  }
  return 0
}

# Collect a line while inside a when block. Returns "" always.
# Branch headers set state; body lines are buffered; "end" triggers emit.
function _ds_match_collect(line, lineno,    d, m, i) {
  if (_ds_match_starts(line, m, lineno)) return ""
  d = _DS_match_depth
  # ok name:  (ok, bind)
  if (match(line, /^[[:space:]]*ok[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
    _ds_match_unregister_current_arm(d)
    if (_ds_match_check_shadow(d, m[1], lineno)) {
      _ds_match_shadow_recover(d)
      return ""
    }
    _DS_match_bind_seen[d, "ok", m[1]] = 1
    _DS_match_active_bind[d] = m[1]
    _DS_match_ok_var[d] = m[1]; _DS_match_branch[d] = "ok"
    return ""
  }
  # ok:  (ok, no bind)
  if (line ~ /^[[:space:]]*ok:[[:space:]]*$/) {
    _ds_match_unregister_current_arm(d)
    delete _DS_match_active_bind[d]
    _DS_match_ok_var[d] = ""; _DS_match_branch[d] = "ok"; return ""
  }
  # some name:  (some, bind)
  if (match(line, /^[[:space:]]*some[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
    _ds_match_unregister_current_arm(d)
    if (_ds_match_check_shadow(d, m[1], lineno)) {
      _ds_match_shadow_recover(d)
      return ""
    }
    _DS_match_bind_seen[d, "some", m[1]] = 1
    _DS_match_active_bind[d] = m[1]
    _DS_match_ok_var[d] = m[1]; _DS_match_branch[d] = "some"; _DS_match_is_option[d] = 1
    return ""
  }
  # some:  (some, no bind)
  if (line ~ /^[[:space:]]*some:[[:space:]]*$/) {
    _ds_match_unregister_current_arm(d)
    delete _DS_match_active_bind[d]
    _DS_match_ok_var[d] = ""; _DS_match_branch[d] = "some"; _DS_match_is_option[d] = 1; return ""
  }
  # none:  (none, no bind — treated as default arm for option)
  if (line ~ /^[[:space:]]*none:[[:space:]]*$/) {
    if (_ds_saw_catchall[d]) _ds_match_catchall_order_error()
    _ds_match_unregister_current_arm(d)
    delete _DS_match_active_bind[d]
    i = ++_DS_match_ng_arms[d]; _DS_match_cur_ng_arm[d] = i
    _DS_match_ng_type[d, i] = ""; _DS_match_ng_var_name[d, i] = ""
    _ds_saw_catchall[d] = 1
    _DS_match_ng_is_default[d, i] = 1; _DS_match_branch[d] = "ng"; return ""
  }
  # ng VAR<TypeName>:  (typed ng, bind — check BEFORE plain "ng name:")
  if (match(line, /^[[:space:]]*ng[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)<([^>]+)>[[:space:]]*:[[:space:]]*$/, m)) {
    if (_ds_saw_catchall[d]) _ds_match_catchall_order_error()
    _ds_match_unregister_current_arm(d)
    if (_ds_match_check_shadow(d, m[1], lineno)) {
      _ds_match_shadow_recover(d)
      return ""
    }
    _DS_match_bind_seen[d, "ng", m[1]] = 1
    _DS_match_active_bind[d] = m[1]
    i = ++_DS_match_ng_arms[d]; _DS_match_cur_ng_arm[d] = i
    _DS_match_ng_type[d, i] = m[2]; _DS_match_ng_var_name[d, i] = m[1]
    _DS_match_ng_is_default[d, i] = 0; _DS_match_branch[d] = "ng"
    return ""
  }
  # ng <TypeName>:  (typed ng, no bind)
  if (match(line, /^[[:space:]]*ng[[:space:]]*<([^>]+)>[[:space:]]*:[[:space:]]*$/, m)) {
    if (_ds_saw_catchall[d]) _ds_match_catchall_order_error()
    _ds_match_unregister_current_arm(d)
    delete _DS_match_active_bind[d]
    i = ++_DS_match_ng_arms[d]; _DS_match_cur_ng_arm[d] = i
    _DS_match_ng_type[d, i] = m[1]; _DS_match_ng_var_name[d, i] = ""
    _DS_match_ng_is_default[d, i] = 0; _DS_match_branch[d] = "ng"; return ""
  }
  # ng name:  (untyped ng, bind)
  if (match(line, /^[[:space:]]*ng[[:space:]]+([a-z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
    if (_ds_saw_catchall[d]) _ds_match_catchall_order_error()
    _ds_match_unregister_current_arm(d)
    if (_ds_match_check_shadow(d, m[1], lineno)) {
      _ds_match_shadow_recover(d)
      return ""
    }
    _DS_match_bind_seen[d, "ng", m[1]] = 1
    _DS_match_active_bind[d] = m[1]
    i = ++_DS_match_ng_arms[d]; _DS_match_cur_ng_arm[d] = i
    _DS_match_ng_type[d, i] = ""; _DS_match_ng_var_name[d, i] = m[1]
    _ds_saw_catchall[d] = 1
    _DS_match_ng_is_default[d, i] = 0; _DS_match_branch[d] = "ng"
    return ""
  }
  # ng:  (untyped ng, no bind)
  if (line ~ /^[[:space:]]*ng:[[:space:]]*$/) {
    if (_ds_saw_catchall[d]) _ds_match_catchall_order_error()
    _ds_match_unregister_current_arm(d)
    delete _DS_match_active_bind[d]
    i = ++_DS_match_ng_arms[d]; _DS_match_cur_ng_arm[d] = i
    _DS_match_ng_type[d, i] = ""; _DS_match_ng_var_name[d, i] = ""
    _ds_saw_catchall[d] = 1
    _DS_match_ng_is_default[d, i] = 0; _DS_match_branch[d] = "ng"; return ""
  }
  # default name:  (catch-all, bind)
  if (match(line, /^[[:space:]]*default[[:space:]]+([a-z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*$/, m)) {
    if (_ds_saw_catchall[d]) _ds_match_catchall_order_error()
    _ds_match_unregister_current_arm(d)
    if (_ds_match_check_shadow(d, m[1], lineno)) {
      _ds_match_shadow_recover(d)
      return ""
    }
    _DS_match_bind_seen[d, "ng", m[1]] = 1
    _DS_match_active_bind[d] = m[1]
    i = ++_DS_match_ng_arms[d]; _DS_match_cur_ng_arm[d] = i
    _DS_match_ng_type[d, i] = ""; _DS_match_ng_var_name[d, i] = m[1]
    _ds_saw_catchall[d] = 1
    _DS_match_ng_is_default[d, i] = 1; _DS_match_branch[d] = "ng"
    return ""
  }
  # default:  (catch-all, no bind)
  if (line ~ /^[[:space:]]*default:[[:space:]]*$/) {
    if (_ds_saw_catchall[d]) _ds_match_catchall_order_error()
    _ds_match_unregister_current_arm(d)
    delete _DS_match_active_bind[d]
    i = ++_DS_match_ng_arms[d]; _DS_match_cur_ng_arm[d] = i
    _DS_match_ng_type[d, i] = ""; _DS_match_ng_var_name[d, i] = ""
    _ds_saw_catchall[d] = 1
    _DS_match_ng_is_default[d, i] = 1; _DS_match_branch[d] = "ng"; return ""
  }
  # end
  if (line ~ /^[[:space:]]*end[[:space:]]*$/) {
    _ds_match_unregister_current_arm(d)
    if (_DS_match_shadow_abort[d]) {
      _ds_match_reset(d)
      _DS_match_depth--
      if (_DS_match_depth == 0) _DS_in_match = 0
      return ""
    }
    _ds_match_emit(lineno, d)
    _ds_match_reset(d)
    _DS_match_depth--
    if (_DS_match_depth == 0) _DS_in_match = 0
    return ""
  }
  # Body line — buffer under current branch
  if (_DS_match_branch[d] == "ok" || _DS_match_branch[d] == "some") {
    ++_DS_match_ok_count[d]
    _DS_match_ok_body[d, _DS_match_ok_count[d]] = line
    _DS_match_ok_lineno[d, _DS_match_ok_count[d]] = lineno
  } else {
    i = _DS_match_cur_ng_arm[d]
    if (i == 0) {
      _ds_error(lineno, "when...of body line before any arm", \
          "move this line inside an ok:, ng:, or default: arm")
      return ""
    }
    ++_DS_match_ng_body_count[d, i]
    _DS_match_ng_body[d, i, _DS_match_ng_body_count[d, i]] = line
    _DS_match_ng_lineno[d, i, _DS_match_ng_body_count[d, i]] = lineno
  }
  return ""
}

function _ds_match_check_shadow(d, name, lineno) {
  if ((d, name) in _DS_match_outer_binds) {
    printf "desugar: error: '%s' shadows outer when arm binding (depth %d)\n", name, d > "/dev/stderr"
    print "hint: rename the inner binding" > "/dev/stderr"
    _DS_had_error = 1
    return 1
  }
  return 0
}

function _ds_match_shadow_recover(d,    skip_line, parent, skip_depth) {
  _ds_match_reset(d)
  _DS_match_depth--
  parent = _DS_match_depth
  if (parent >= 1) _DS_match_shadow_abort[parent] = 1
  if (_DS_match_depth == 0) _DS_in_match = 0
  skip_depth = 0
  while ((getline skip_line) > 0) {
    if (skip_line ~ /^[[:space:]]*when[[:space:]].*[[:space:]]of[[:space:]]*$/) {
      skip_depth++
      continue
    }
    if (skip_line ~ /^[[:space:]]*end[[:space:]]*$/) {
      if (skip_depth == 0) return
      skip_depth--
    }
  }
}

function _ds_match_catchall_order_error() {
  print "desugar: error: catch-all arm must be last" > "/dev/stderr"
  _DS_had_error = 1
  exit 1
}

function _ds_match_register_arm_bind_type(d, branch_kind, func_name, var_name, type_str,    idx) {
  if (func_name == "" || var_name == "") return
  idx = ++_DS_match_arm_var_order_n[d, branch_kind]
  _DS_match_arm_var_order[d, branch_kind, idx] = var_name
  if ((func_name SUBSEP var_name) in _DS_VAR_TYPES)
    _DS_match_arm_var_type[d, branch_kind, func_name, var_name, "_shadowed"] = _DS_VAR_TYPES[func_name, var_name]
  _DS_match_arm_var_type[d, branch_kind, func_name, var_name] = type_str
  _DS_VAR_TYPES[func_name, var_name] = type_str
}

function _ds_match_unregister_current_arm(d,    branch_kind) {
  if (!_DS_in_function) return
  if (_DS_match_branch[d] == "ok" || _DS_match_branch[d] == "some")
    branch_kind = "ok"
  else if (_DS_match_branch[d] == "ng")
    branch_kind = "ng"
  if (branch_kind != "" && _DS_match_arm_var_order_n[d, branch_kind] > 0)
    _ds_match_unregister_arm_bind_types(d, branch_kind, _DS_func_name)
}

function _ds_match_unregister_arm_bind_types(d, branch_kind, func_name) {
  _ds_match_rollback_arm_bind_types(d, branch_kind, func_name)
}

function _ds_match_rollback_arm_bind_types(d, branch_kind, func_name,    idx, var_name) {
  if (func_name == "") return
  for (idx = _DS_match_arm_var_order_n[d, branch_kind]; idx >= 1; idx--) {
    var_name = _DS_match_arm_var_order[d, branch_kind, idx]
    if ((d, branch_kind, func_name, var_name, "_shadowed") in _DS_match_arm_var_type) {
      _DS_VAR_TYPES[func_name, var_name] = _DS_match_arm_var_type[d, branch_kind, func_name, var_name, "_shadowed"]
      delete _DS_match_arm_var_type[d, branch_kind, func_name, var_name, "_shadowed"]
    } else {
      delete _DS_VAR_TYPES[func_name, var_name]
    }
    delete _DS_match_arm_var_type[d, branch_kind, func_name, var_name]
    delete _DS_match_arm_var_order[d, branch_kind, idx]
  }
  delete _DS_match_arm_var_order_n[d, branch_kind]
}

# Reset one match frame.
function _ds_match_reset(d) {
  _ds_match_rollback_arm_bind_types(d, "ng", _DS_func_name)
  _ds_match_rollback_arm_bind_types(d, "ok", _DS_func_name)
  _ds_match_delete_depth(_DS_match_arm_var_type, d)
  _ds_match_delete_depth(_DS_match_arm_var_order, d)
  _ds_match_delete_depth(_DS_match_arm_var_order_n, d)
  delete _DS_match_ok_count[d]
  delete _DS_match_ok_var[d]
  delete _DS_match_branch[d]
  delete _DS_match_expr[d]
  delete _DS_match_indent[d]
  delete _DS_match_lineno[d]
  delete _DS_match_ng_arms[d]
  delete _DS_match_cur_ng_arm[d]
  delete _DS_match_is_option[d]
  delete _ds_saw_catchall[d]
  _ds_match_delete_depth(_DS_match_ok_body, d)
  _ds_match_delete_depth(_DS_match_ok_lineno, d)
  _ds_match_delete_depth(_DS_match_ok_raw, d)
  _ds_match_delete_depth(_DS_match_ng_body, d)
  _ds_match_delete_depth(_DS_match_ng_lineno, d)
  _ds_match_delete_depth(_DS_match_ng_raw, d)
  _ds_match_delete_depth(_DS_match_ng_type, d)
  _ds_match_delete_depth(_DS_match_ng_var_name, d)
  _ds_match_delete_depth(_DS_match_ng_is_default, d)
  _ds_match_delete_depth(_DS_match_ng_body_count, d)
  _ds_match_delete_depth(_DS_match_outer_binds, d)
  _ds_match_delete_depth(_DS_match_bind_seen, d)
  delete _DS_match_active_bind[d]
  delete _DS_match_shadow_abort[d]
}

function _ds_match_delete_depth(a, d,    k, parts) {
  for (k in a) {
    split(k, parts, SUBSEP)
    if (parts[1] == d) delete a[k]
  }
}

# Emit desugared if/else into _DS_body_buf.
function _ds_match_emit(lineno, d,    tmpvar, type_t, check_fn, val_fn, err_fn, i, j, arm_type, arm_var, arm_default, _ds_emit_added_vars, _ds_union_members, _ds_n_union, _ds_has_catchall, _ds_covered, emit_base, header_lineno, _saved_lineno) {
  if (_DS_match_ng_arms[d] == 0) {
    _ds_error(lineno, "when...of missing ng/none/default branch", \
        "add an ng: or default: arm to handle the error case")
    return
  }

  _DS_mc_count++
  tmpvar = "_ds_mc_" _DS_mc_count

  header_lineno = (_DS_match_lineno[d] != "" ? _DS_match_lineno[d] : lineno)
  _saved_lineno = _DS_current_lineno
  _DS_current_lineno = header_lineno
  type_t = _ds_infer_type(_DS_match_expr[d])
  _DS_current_lineno = _saved_lineno
  type_t = _ds_strip_effect(type_t)

  if (_DS_in_function) {
    _ds_match_add_local(tmpvar)
    if (_DS_match_ok_var[d] != "") _ds_match_add_local(_DS_match_ok_var[d])
    # Deduplicate: multiple arms may bind to the same var name
    delete _ds_emit_added_vars
    for (i = 1; i <= _DS_match_ng_arms[d]; i++) {
      if (_DS_match_ng_var_name[d, i] != "" && !(_DS_match_ng_var_name[d, i] in _ds_emit_added_vars)) {
        _ds_match_add_local(_DS_match_ng_var_name[d, i])
        _ds_emit_added_vars[_DS_match_ng_var_name[d, i]] = 1
      }
    }
  }

  if (type_t ~ /^Option</ || (type_t == "" && _DS_match_is_option[d])) {
    check_fn = "option_some"; val_fn = "option_val"; err_fn = ""
  } else {
    check_fn = "result_ok"; val_fn = "result_val"; err_fn = "result_err"
  }

  # Exhaustiveness check: Result<T, E1|E2|...> with typed arms must cover every member
  # OR have a catch-all (default:/ng:) arm.
  if (type_t ~ /^Result</ && _DS_match_ng_arms[d] > 0) {
    delete _ds_union_members
    _ds_n_union = _ds_result_err_union(type_t, _ds_union_members)
    if (_ds_n_union > 1) {
      _ds_has_catchall = 0
      for (i = 1; i <= _DS_match_ng_arms[d]; i++) {
        if (_DS_match_ng_is_default[d, i] || _DS_match_ng_type[d, i] == "") {
          _ds_has_catchall = 1; break
        }
      }
      if (!_ds_has_catchall) {
        delete _ds_covered
        for (i = 1; i <= _DS_match_ng_arms[d]; i++)
          if (_DS_match_ng_type[d, i] != "") _ds_covered[_DS_match_ng_type[d, i]] = 1
        for (i = 1; i <= _ds_n_union; i++) {
          if (!(_ds_union_members[i] in _ds_covered)) {
            _ds_error(header_lineno, \
              "when...of missing arm for " _ds_union_members[i], \
              "add 'ng e<" _ds_union_members[i] ">:' or 'default:'")
          }
        }
        if (_DS_had_error) return
      }
    }
  }

  emit_base = _DS_body_count
  _ds_match_push(_DS_match_indent[d] tmpvar " = " _ds_dot_transform(_DS_match_expr[d]), header_lineno)
  _ds_match_push(_DS_match_indent[d] "if (" check_fn "(" tmpvar ")) {", header_lineno)
  if (_DS_match_ok_var[d] != "")
    _ds_match_push(_DS_match_indent[d] "  " _DS_match_ok_var[d] " = " val_fn "(" tmpvar ")", header_lineno)
  if (_DS_in_function && _DS_match_ok_var[d] != "")
    _ds_match_register_arm_bind_type(d, "ok", _DS_func_name, _DS_match_ok_var[d], _ds_inner_type(type_t))
  for (j = 1; j <= _DS_match_ok_count[d]; j++) {
    if (_DS_match_ok_raw[d, j])
      _ds_match_push(_DS_match_ok_body[d, j], _DS_match_ok_lineno[d, j])
    else
      _ds_match_process_body(_DS_match_ok_body[d, j], _DS_match_ok_lineno[d, j], d)
  }
  if (_DS_in_function && _DS_match_ok_var[d] != "")
    _ds_match_unregister_arm_bind_types(d, "ok", _DS_func_name)

  for (i = 1; i <= _DS_match_ng_arms[d]; i++) {
    arm_type    = _DS_match_ng_type[d, i]
    arm_var     = _DS_match_ng_var_name[d, i]
    arm_default = _DS_match_ng_is_default[d, i]

    if (arm_type != "" && !arm_default) {
      _ds_match_push(_DS_match_indent[d] "} else if (result_err_type(" tmpvar ") == \"" arm_type "\") {", header_lineno)
    } else {
      _ds_match_push(_DS_match_indent[d] "} else {", header_lineno)
    }

    if (arm_var != "" && err_fn != "")
      _ds_match_push(_DS_match_indent[d] "  " arm_var " = " err_fn "(" tmpvar ")", header_lineno)

    if (_DS_in_function && arm_var != "" && err_fn != "")
      _ds_match_register_arm_bind_type(d, "ng", _DS_func_name, arm_var, (arm_type != "" ? arm_type : _ds_result_err_type(type_t)))
    for (j = 1; j <= _DS_match_ng_body_count[d, i]; j++) {
      if (_DS_match_ng_raw[d, i, j])
        _ds_match_push(_DS_match_ng_body[d, i, j], _DS_match_ng_lineno[d, i, j])
      else
        _ds_match_process_body(_DS_match_ng_body[d, i, j], _DS_match_ng_lineno[d, i, j], d)
    }
    if (_DS_in_function && arm_var != "" && err_fn != "")
      _ds_match_unregister_arm_bind_types(d, "ng", _DS_func_name)
  }

  _ds_match_push(_DS_match_indent[d] "}", header_lineno)
  if (d >= 2) _ds_match_move_emit_to_parent(d, emit_base)
}

function _ds_match_add_local(name,    i, lp, rp, params, n, parts, p) {
  if (name == "") return
  for (i = 1; i <= _DS_let_count; i++)
    if (_DS_let_locals[i] == name) return

  lp = index(_DS_func_sig, "(")
  rp = index(_DS_func_sig, ")")
  if (lp > 0 && rp > lp + 1) {
    params = substr(_DS_func_sig, lp + 1, rp - lp - 1)
    n = split(params, parts, ",")
    for (i = 1; i <= n; i++) {
      p = _ds_trim(parts[i])
      if (p == name) return
    }
  }

  _DS_let_locals[++_DS_let_count] = name
}

function _ds_match_push(line, lineno) {
  _DS_body_buf[++_DS_body_count] = line
  _DS_body_lineno[_DS_body_count] = lineno
}

function _ds_match_move_emit_to_parent(d, emit_base,    parent, i, base, cur) {
  parent = d - 1
  if (_DS_match_branch[parent] == "ok" || _DS_match_branch[parent] == "some") {
    base = _DS_match_ok_count[parent]
    for (i = emit_base + 1; i <= _DS_body_count; i++) {
      _DS_match_ok_body[parent, base + i - emit_base] = _DS_body_buf[i]
      _DS_match_ok_lineno[parent, base + i - emit_base] = _DS_body_lineno[i]
      _DS_match_ok_raw[parent, base + i - emit_base] = 1
      delete _DS_body_buf[i]
      delete _DS_body_lineno[i]
    }
    _DS_match_ok_count[parent] = base + _DS_body_count - emit_base
  } else {
    cur = _DS_match_cur_ng_arm[parent]
    base = _DS_match_ng_body_count[parent, cur]
    for (i = emit_base + 1; i <= _DS_body_count; i++) {
      _DS_match_ng_body[parent, cur, base + i - emit_base] = _DS_body_buf[i]
      _DS_match_ng_lineno[parent, cur, base + i - emit_base] = _DS_body_lineno[i]
      _DS_match_ng_raw[parent, cur, base + i - emit_base] = 1
      delete _DS_body_buf[i]
      delete _DS_body_lineno[i]
    }
    _DS_match_ng_body_count[parent, cur] = base + _DS_body_count - emit_base
  }
  _DS_body_count = emit_base
}

# Process a collected body line through the full pipeline, push to _DS_body_buf.
# Normalizes indentation: strips original leading whitespace and prepends _DS_match_indent "  ".
function _ds_match_process_body(line, lineno, d,    pipe_pre, nc_pre, p, pipe_r, dot_r, nc_r, xf) {
  _DS_current_lineno = lineno
  # Normalize indentation: strip original leading whitespace, apply canonical indent
  sub(/^[[:space:]]*/, _DS_match_indent[d] "  ", line)
  line = _ds_fold_adjacent_strings_inline(line)
  if (line ~ /safe\.html\.fragment\(/) {
    _DS_last_interp_untrusted = 0
    line = _ds_expand_fragment_interp(line, lineno)
  }
  if (line ~ /#{/) {
    _DS_last_interp_untrusted = 0
    line = _ds_expand_interp(line, lineno)
  }
  pipe_r = _ds_pipe_transform(line, pipe_pre)
  for (p = 1; p in pipe_pre; p++) _ds_match_push(_ds_dot_transform(pipe_pre[p]), lineno)
  dot_r = _ds_dot_transform(pipe_r)
  nc_r  = _ds_nc_transform(dot_r, nc_pre)
  for (p = 1; p in nc_pre; p++) _ds_match_push(nc_pre[p], lineno)
  _ds_typecheck_plain_call(nc_r)
  _ds_check_return(dot_r, lineno)
  xf = _ds_let_transform(nc_r, lineno, line)
  if (xf != "") _ds_match_push(xf, lineno)
}
