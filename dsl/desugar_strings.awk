# SPDX-License-Identifier: MIT
# dsl/desugar_strings.awk -- string/comment region detection
# Initial stub: treats entire line as safe code. Task 6 replaces this.

function _ds_split_code_segs(line, segs,    n) {
  n = 1
  segs[1, "safe"] = 1
  segs[1, "text"] = line
  return n
}
