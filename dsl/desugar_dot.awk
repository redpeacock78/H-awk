# SPDX-License-Identifier: MIT
# dsl/desugar_dot.awk -- dot-notation → ns::dispatch(path, args) transform

function _ds_dot_transform(line,    result, segs, n, i) {
  n = _ds_split_code_segs(line, segs)
  result = ""
  for (i = 1; i <= n; i++) {
    if (segs[i, "safe"])
      result = result _ds_dot_transform_code(segs[i, "text"])
    else
      result = result segs[i, "text"]
  }
  return result
}

function _ds_dot_transform_code(seg,    result, m, ns, path, args, n, parts, i) {
  result = ""
  while (match(seg, /[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)+\(/)) {
    result = result substr(seg, 1, RSTART - 1)
    m   = substr(seg, RSTART, RLENGTH - 1)   # matched chain without "("
    seg = substr(seg, RSTART + RLENGTH)       # rest after "("
    n   = split(m, parts, ".")
    ns  = parts[1]
    path = ""
    for (i = 2; i <= n; i++)
      path = path (i > 2 ? "." : "") parts[i]
    args = _ds_extract_args(seg)
    seg  = substr(seg, length(args) + 2)      # skip args + ")"
    result = result ns "::dispatch(\"" path "\"" (args != "" ? ", " args : "") ")"
  }
  return result seg
}

function _ds_extract_args(str,    depth, i, c, n, chars, args) {
  depth = 1; args = ""
  n = split(str, chars, "")
  for (i = 1; i <= n; i++) {
    c = chars[i]
    if      (c == "(") depth++
    else if (c == ")") { depth--; if (depth == 0) break }
    args = args c
  }
  return args
}
