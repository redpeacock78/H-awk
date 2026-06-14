# SPDX-License-Identifier: MIT
# dsl/desugar_strings.awk -- string/comment region detection

function _ds_split_code_segs(line, segs,    n, chars, nchars, i, c, in_str, seg_safe, seg_text, rest) {
  n = 0
  nchars = split(line, chars, "")
  in_str = 0
  seg_safe = 1
  seg_text = ""

  for (i = 1; i <= nchars; i++) {
    c = chars[i]
    if (!in_str) {
      if (c == "#") {
        # flush current segment
        if (seg_text != "") { n++; segs[n, "safe"] = seg_safe; segs[n, "text"] = seg_text; seg_text = "" }
        # rest of line is comment (unsafe)
        rest = ""
        for (; i <= nchars; i++) rest = rest chars[i]
        n++; segs[n, "safe"] = 0; segs[n, "text"] = rest
        return n
      } else if (c == "\"") {
        # flush code segment, start string
        if (seg_text != "") { n++; segs[n, "safe"] = seg_safe; segs[n, "text"] = seg_text; seg_text = "" }
        in_str = 1; seg_safe = 0; seg_text = c
      } else {
        if (seg_safe != 1 && seg_text != "") { n++; segs[n, "safe"] = seg_safe; segs[n, "text"] = seg_text; seg_text = ""; seg_safe = 1 }
        seg_text = seg_text c
      }
    } else {
      # inside string
      if (c == "\\" && i < nchars) {
        seg_text = seg_text c chars[++i]  # consume escape
      } else if (c == "\"") {
        seg_text = seg_text c  # include closing quote
        # flush string segment, back to code
        n++; segs[n, "safe"] = seg_safe; segs[n, "text"] = seg_text; seg_text = ""
        in_str = 0; seg_safe = 1
      } else {
        seg_text = seg_text c
      }
    }
  }
  if (seg_text != "") { n++; segs[n, "safe"] = seg_safe; segs[n, "text"] = seg_text }
  if (n == 0) { n = 1; segs[1, "safe"] = 1; segs[1, "text"] = "" }
  return n
}

# _ds_string_literal_content(s): strip outer quotes from a string literal
# "foo" -> foo,  "foo\"bar" -> foo\"bar
function _ds_string_literal_content(s) {
  return substr(s, 2, length(s) - 2)
}

# _ds_is_pure_string_line(line): 1 if line has only whitespace + exactly one string literal
function _ds_is_pure_string_line(line,    segs, n, i, nstr) {
  n = _ds_split_code_segs(line, segs)
  nstr = 0
  for (i = 1; i <= n; i++) {
    if (segs[i, "safe"] == 0) {
      # Non-safe segment: must be a string literal (starts with ")
      if (segs[i, "text"] ~ /^"/) {
        nstr++
      } else {
        # Comment or unknown non-safe segment
        return 0
      }
    } else {
      # Code segment: must be only whitespace
      if (segs[i, "text"] !~ /^[[:space:]]*$/) return 0
    }
  }
  return (nstr == 1)
}

# _ds_pure_string_line_content(line): extract inner content from a pure string line
function _ds_pure_string_line_content(line,    segs, n, i) {
  n = _ds_split_code_segs(line, segs)
  for (i = 1; i <= n; i++) {
    if (segs[i, "safe"] == 0 && segs[i, "text"] ~ /^"/) {
      return _ds_string_literal_content(segs[i, "text"])
    }
  }
  return ""
}

# _ds_is_let_equals_no_rhs(line): matches "let <ident>[: <type>] =" with nothing after
function _ds_is_let_equals_no_rhs(line) {
  return (line ~ /^[[:space:]]*let[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*([[:space:]]*:[[:space:]]*[^=]+)?[[:space:]]*=[[:space:]]*$/)
}

# _ds_fold_adjacent_strings_inline(line): merge adjacent string literals on one line
# "foo" "bar" -> "foobar"; does not touch non-string tokens
function _ds_fold_adjacent_strings_inline(line,    segs, n, i, j, k, out, merged) {
  n = _ds_split_code_segs(line, segs)
  if (n == 0) return line

  # Repeatedly merge pairs of adjacent string literals separated by whitespace-only
  merged = 1
  while (merged) {
    merged = 0
    for (i = 1; i <= n - 1; i++) {
      if (segs[i, "safe"] == 0 && segs[i, "text"] ~ /^"/) {
        # Find next non-whitespace segment
        j = i + 1
        while (j <= n && segs[j, "safe"] == 1 && segs[j, "text"] ~ /^[[:space:]]*$/) j++
        if (j <= n && segs[j, "safe"] == 0 && segs[j, "text"] ~ /^"/) {
          # Merge segs[i] and segs[j]
          segs[i, "text"] = "\"" _ds_string_literal_content(segs[i, "text"]) \
                                  _ds_string_literal_content(segs[j, "text"]) "\""
          # Remove segments i+1 through j (the whitespace and the merged string)
          for (k = i + 1; k <= n - (j - i); k++) {
            segs[k, "safe"] = segs[k + (j - i), "safe"]
            segs[k, "text"] = segs[k + (j - i), "text"]
          }
          for (k = n - (j - i) + 1; k <= n; k++) {
            delete segs[k, "safe"]
            delete segs[k, "text"]
          }
          n = n - (j - i)
          merged = 1
          break
        }
      }
    }
  }

  out = ""
  for (i = 1; i <= n; i++) out = out segs[i, "text"]
  return out
}
