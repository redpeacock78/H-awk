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
