# SPDX-License-Identifier: MIT

function v2_diag(line, col, msg) {
  printf("%s:%d:%d: error: %s\n", V2_SRC, line, col, msg) > "/dev/stderr"
  V2_NERRORS++
}

function v2_dump_types(  id) {
  for (id = 1; id <= V2_NAST; id++)
    if ((id) in TYPEOF)
      printf("%d\t%s\n", id, TYPEOF[id])
}

function v2_emit(  stmt_id) {
  for (stmt_id = 1; stmt_id <= V2_NAST; stmt_id++)
    if ((stmt_id) in V2_AST)
      print V2_AST[stmt_id]
}
