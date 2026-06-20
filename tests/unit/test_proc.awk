# SPDX-License-Identifier: MIT
# tests/unit/test_proc.awk

function test_proc_self_has_value(    s) {
  s = proc::self()
  assert_true(length(s) > 0, "proc: self() returns non-empty")
}

function test_proc_self_env(    saved) {
  saved = ENVIRON["HAWK_PROC_ID"]
  ENVIRON["HAWK_PROC_ID"] = "web:3"
  assert_eq(proc::self(), "web:3", "proc: self() returns HAWK_PROC_ID")
  ENVIRON["HAWK_PROC_ID"] = saved
}

function test_proc_register_whereis(    saved) {
  saved = ENVIRON["HAWK_PROC_ID"]
  ENVIRON["HAWK_PROC_ID"] = "web:0"
  objectspace::_reset()
  proc::register("myservice", "proc://svc/1")
  assert_eq(proc::whereis("myservice"), "proc://svc/1", "proc: register/whereis")
  ENVIRON["HAWK_PROC_ID"] = saved
}

function test_proc_whereis_unknown() {
  objectspace::_reset()
  assert_eq(proc::whereis("no_such"), "", "proc: whereis unknown = empty")
}
