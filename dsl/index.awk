# SPDX-License-Identifier: MIT
@include "dsl/util.awk"
@include "dsl/lex.awk"
@include "dsl/rpn.awk"
@include "dsl/parse.awk"
@include "dsl/check.awk"

function q(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  return "\"" s "\""
}

function emit_shared(out,    k, p, n, v) {
  print "BEGIN {" > out
  for (k in V2_RECORD_TYPE)
    printf "  V2_SHARED_RECORD_TYPE[%s] = 1\n", q(k) > out
  for (k in V2_RECORD_FIELDS) {
    split(k, p, SUBSEP)
    printf "  V2_SHARED_RECORD_FIELDS[%s, %s] = %s\n", q(p[1]), q(p[2]), q(V2_RECORD_FIELDS[k]) > out
  }
  for (k in ALIAS)
    printf "  V2_SHARED_ALIAS[%s] = %s\n", q(k), q(ALIAS[k]) > out
  for (k in SIG) {
    split(k, p, SUBSEP)
    printf "  V2_SHARED_SIG[%s, %s] = %s\n", q(p[1]), q(p[2]), q(SIG[k]) > out
  }
  for (k in V2_RAW_FUNC)
    printf "  V2_SHARED_RAW_FUNC[%s] = 1\n", q(k) > out
  print "}" > out
}

BEGIN {
  if (V2_INDEX_LIST == "") exit 1
  V2_INDEX_MODE = 1
  n = split(V2_INDEX_LIST, files, SUBSEP)
  for (i = 1; i <= n; i++) {
    if (files[i] == "") continue
    delete V2_INDEX_RUN_FIELDS
    delete V2_INDEX_RUN_RECORDS
    delete V2_INDEX_OLD_FIELDS
    for (k in V2_INDEX_RECORD_FIELDS) V2_INDEX_OLD_FIELDS[k] = V2_INDEX_RECORD_FIELDS[k]
    delete V2_INDEX_OLD_RECORDS
    for (k in V2_INDEX_RECORD_NAMES) V2_INDEX_OLD_RECORDS[k] = 1
    v2_lex(files[i])
    v2_rpn()
    for (k in V2_RECORD_FIELDS) {
      if ((k in V2_INDEX_RECORD_FIELDS) && V2_INDEX_RECORD_FIELDS[k] != V2_RECORD_FIELDS[k]) {
        print "[hawk-libs] index failed: conflicting record field definition" > "/dev/stderr"
        exit 1
      }
      V2_INDEX_RECORD_FIELDS[k] = V2_RECORD_FIELDS[k]
    }
    for (k in V2_INDEX_OLD_FIELDS) {
      split(k, p, SUBSEP)
      if ((p[1] in V2_INDEX_RUN_RECORDS) && !(k in V2_INDEX_RUN_FIELDS)) {
        print "[hawk-libs] index failed: conflicting record field definition" > "/dev/stderr"
        exit 1
      }
    }
    for (k in V2_INDEX_RUN_FIELDS) {
      split(k, p, SUBSEP)
      if ((p[1] in V2_INDEX_OLD_RECORDS) && !(k in V2_INDEX_OLD_FIELDS)) {
        print "[hawk-libs] index failed: conflicting record field definition" > "/dev/stderr"
        exit 1
      }
    }
    for (k in V2_INDEX_RUN_RECORDS) V2_INDEX_RECORD_NAMES[k] = 1
    v2_parse()
    v2_collect(1)
    v2_collect_raw_funcs()
    for (k in ALIAS) {
      if ((k in V2_INDEX_ALIAS) && V2_INDEX_ALIAS[k] != ALIAS[k]) {
        print "[hawk-libs] index failed: conflicting type alias definition: " k > "/dev/stderr"
        exit 1
      }
      V2_INDEX_ALIAS[k] = ALIAS[k]
    }
    for (k in SIG) {
      if ((k in V2_INDEX_SIG) && V2_INDEX_SIG[k] != SIG[k]) {
        print "[hawk-libs] index failed: conflicting function signature: " k > "/dev/stderr"
        exit 1
      }
      V2_INDEX_SIG[k] = SIG[k]
    }
  }
  emit_shared(V2_INDEX_OUT)
  exit 0
}
