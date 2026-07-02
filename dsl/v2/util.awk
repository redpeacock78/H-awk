# SPDX-License-Identifier: MIT
# dsl/v2/util.awk -- 診断と共通ヘルパー

function v2_diag(line, col, msg) {
  printf "%s:%d:%d: error: %s\n", V2_SRC, line, col, msg > "/dev/stderr"
  V2_ERRORS++
}
