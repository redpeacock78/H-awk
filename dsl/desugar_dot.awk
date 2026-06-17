# SPDX-License-Identifier: MIT
# dsl/desugar_dot.awk -- dot-notation → ns::dispatch(path, args) transform

# Transform a full line. Dot-calls inside strings or after # are not touched.
# Strategy: collect the "current code run", try matching dot-calls in it.
# When a match is found, output pre-match verbatim, emit dispatch, then skip
# past the args + ")" in the full remaining line.
function _ds_dot_transform(line,    segs, n, i) {
  n = _ds_split_code_segs(line, segs)
  return _ds_dot_transform_segs(segs, n)
}

# Process all segments together so we can skip consumed string segments.
# Returns the fully transformed line.
function _ds_dot_transform_segs(segs, n,    result, i, code_buf, skip_chars) {
  result = ""
  i = 1
  while (i <= n) {
    if (segs[i, "safe"]) {
      # Try to find a dot-call in this code segment
      if (match(segs[i, "safe"] ? segs[i, "text"] : "", \
                /[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)+\(/)) {
        # Found a dot-call at RSTART..RSTART+RLENGTH-1 in segs[i,"text"]
        result = result substr(segs[i, "text"], 1, RSTART - 1)

        # m = dot-chain without the trailing "("
        # Build suffix = segs[i,"text"] after "(" + all remaining segments
        code_buf = substr(segs[i, "text"], RSTART, RLENGTH - 1)  # chain
        # Full "rest" = everything after "(" across all remaining segments
        # We need to extract args from this combined rest
        result = result _ds_dispatch_from(code_buf, segs, n, i, \
                           substr(segs[i, "text"], RSTART + RLENGTH), i + 1)
        # After dispatch, i and the segments are consumed — return remainder
        return result
      } else {
        result = result segs[i, "text"]
      }
    } else {
      result = result segs[i, "text"]
    }
    i++
  }
  return result
}

# Given dot-chain m (without "("), build the dispatch call.
# Remaining text in the current segment after "(" is cur_rest.
# Subsequent segments start at seg_idx segs[seg_idx..n].
# Recursively handle remaining segments after the ")" is found.
function _ds_dispatch_from(m, segs, n, cur_i, cur_rest, next_i,    \
    ns, path, parts, np, j, args, after_close, rem_seg, rem_segs, k, tmp) {
  # Build full string from cur_rest + subsequent segments
  tmp = cur_rest
  for (k = next_i; k <= n; k++) tmp = tmp segs[k, "text"]

  args = _ds_extract_args(tmp)
  after_close = substr(tmp, length(args) + 2)  # skip args + ")"

  np = split(m, parts, ".")
  ns = parts[1]
  path = ""
  for (j = 2; j <= np; j++)
    path = path (j > 2 ? "." : "") parts[j]

  _ds_typecheck_call(ns "." path, args)

  # option constructors emit direct function calls, not ns::dispatch
  if (ns == "option" && path == "some") {
    return "option_some_make(" (args != "" ? _ds_dot_transform(args) : "") ")" \
           _ds_dot_transform(after_close)
  }
  if (ns == "option" && path == "none") {
    return "option_none_make()" _ds_dot_transform(after_close)
  }

  # Now recursively transform after_close (it's the tail of the line)
  # We need to re-segment after_close and transform it
  # But after_close may start mid-way through a segment — just transform it as a new line
  return ns "::dispatch(\"" path "\"" (args != "" ? ", " _ds_dot_transform(args) : "") ")" \
         _ds_dot_transform(after_close)
}

function _ds_extract_args(str,    depth, i, c, n, chars, args, in_str) {
  depth = 1; args = ""; in_str = 0
  n = split(str, chars, "")
  for (i = 1; i <= n; i++) {
    c = chars[i]
    if (in_str) {
      args = args c
      if (c == "\\" && i < n) { args = args chars[++i] }
      else if (c == "\"") in_str = 0
    } else {
      if      (c == "\"") { in_str = 1; args = args c }
      else if (c == "(")  { depth++; args = args c }
      else if (c == ")") {
        depth--
        if (depth == 0) break
        args = args c
      } else {
        args = args c
      }
    }
  }
  return args
}
