# SPDX-License-Identifier: MIT
# dsl/v2/main.awk -- DSL v2 compiler driver
#
# 工程順: lex -> rpn -> parse -> check -> emit
# V2_DUMP=lex|rpn|ast|types で工程ダンプして終了。

@include "dsl/v2/util.awk"
@include "dsl/v2/lex.awk"
@include "dsl/v2/rpn.awk"

BEGIN {
  V2_SRC = (ARGC > 1) ? ARGV[1] : "/dev/stdin"
  V2_ERRORS = 0
  v2_lex(V2_SRC)
  if (V2_DUMP == "lex")   { v2_dump_lex();   exit(V2_ERRORS ? 1 : 0) }
  v2_rpn()
  if (V2_DUMP == "rpn")   { v2_dump_rpn();   exit(V2_ERRORS ? 1 : 0) }
  v2_parse()
  if (V2_DUMP == "ast")   { v2_dump_ast();   exit(V2_ERRORS ? 1 : 0) }
  v2_check()
  if (V2_DUMP == "types") { v2_dump_types(); exit(V2_ERRORS ? 1 : 0) }
  if (V2_ERRORS) exit 1
  v2_emit()
  exit 0
}

# Task 4 以降で各モジュールに移す仮実装。
function v2_parse() { V2_NAST = 1; AST[1,"kind"] = "PROGRAM"; AST[1,"nc"] = 0 }
function v2_check() { }
function v2_emit(   l) { for (l = 1; l <= V2_NLINES; l++) print PASS[l] }
function v2_dump_lex(   i) { for (i = 1; i <= TOK["n"]; i++) printf "%d\t%s\t%d\t%d\t%s\n", i, TOK[i,"kind"], TOK[i,"line"], TOK[i,"col"], TOK[i,"text"] }
function v2_dump_rpn(   i) { for (i = 1; i <= RPN["n"]; i++) printf "%d\t%s\t%d\t%s\t%s\n", i, RPN[i,"kind"], RPN[i,"line"], RPN[i,"val"], ((RPN[i,"kind"]=="CALL") ? RPN[i,"arity"] : "") }
function v2_dump_ast(   id, k, cs) { for (id = 1; id <= V2_NAST; id++) { cs = ""; for (k = 1; k <= AST[id,"nc"]; k++) cs = cs ((k>1)?",":"") AST[id,"c" k]; printf "%d\t%s\t%d\t%d\t%s\t%s\n", id, AST[id,"kind"], AST[id,"line"], AST[id,"nc"], cs, AST[id,"text"] } }
function v2_dump_types(   id) { for (id = 1; id <= V2_NAST; id++) if ((id) in TYPEOF) printf "%d\t%s\n", id, TYPEOF[id] }
