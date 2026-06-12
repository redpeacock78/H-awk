# SPDX-License-Identifier: MIT
# dsl/desugar_let.awk -- let declaration transform + function signature hoisting

function _ds_let_transform(line, lineno,    arr) {
  # Array init: let name = []
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*\[\][[:space:]]*$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    return arr[1] "delete " arr[2]
  }
  # Assignment: let name = expr
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.+)$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    return arr[1] arr[2] " = " arr[3]
  }
  # Bare declaration: let name
  if (match(line, /^([[:space:]]*)let[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*$/, arr)) {
    _DS_let_locals[++_DS_let_count] = arr[2]
    return ""
  }
  return line
}

function _ds_rewrite_sig(sig,    i, locals_str, lp, rp) {
  if (_DS_let_count == 0) return sig

  # Build comma-joined locals list
  locals_str = ""
  for (i = 1; i <= _DS_let_count; i++)
    locals_str = locals_str (i > 1 ? ", " : "") _DS_let_locals[i]

  # Find opening and closing paren positions
  lp = index(sig, "(")
  rp = index(sig, ")")
  if (lp == 0 || rp == 0) return sig

  # Check if there are existing params (non-empty between parens)
  if (rp > lp + 1) {
    # Has existing params: append ",    locals" before ")"
    return substr(sig, 1, rp - 1) ",    " locals_str substr(sig, rp)
  } else {
    # Empty parens "()" — insert locals inside
    return substr(sig, 1, lp) "    " locals_str substr(sig, rp)
  }
}
