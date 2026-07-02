# SPDX-License-Identifier: MIT

@include "dsl/v2/util.awk"

BEGIN {
  V2_SRC = ARGV[1]
  V2_NERRORS = 0
  V2_NAST = 0
}

{
  V2_NAST++
  V2_AST[V2_NAST] = $0
}

END {
  if (V2_DUMP == "lex") {
    # v2_lex() will be implemented in Task 2
  } else if (V2_DUMP == "rpn") {
    # v2_rpn() will be implemented in Task 3
  } else if (V2_DUMP == "ast") {
    # v2_dump_ast() will be implemented in Task 5
  } else if (V2_DUMP == "types") {
    v2_dump_types()
  } else {
    v2_emit()
  }

  if (V2_NERRORS > 0)
    exit 1
}
