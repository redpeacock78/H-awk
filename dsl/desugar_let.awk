# SPDX-License-Identifier: MIT
# dsl/desugar_let.awk -- let declaration transform + function signature hoisting
# let hoisting is implemented in Task 4. This stub is a passthrough.

function _ds_let_transform(line, lineno) {
  return line
}

function _ds_rewrite_sig(sig) {
  return sig
}
