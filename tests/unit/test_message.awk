# SPDX-License-Identifier: MIT
# tests/unit/test_message.awk

function test_message_make_cast_decode(    enc, out) {
  enc = message::make_cast("proc://cache", "proc://web/0", "at:", "todos")
  delete out
  assert_eq(message::decode(enc, out), 1, "message: decode returns 1")
  assert_eq(out["to"],       "proc://cache",  "message: decode to")
  assert_eq(out["from"],     "proc://web/0",  "message: decode from")
  assert_eq(out["kind"],     "cast",          "message: decode kind")
  assert_eq(out["selector"], "at:",           "message: decode selector")
  assert_eq(out["args"],     "todos",         "message: decode args")
}

function test_message_make_call_has_reply_to(    enc, out) {
  enc = message::make_call("proc://cache", "proc://web/0", "at:", "todos", "/tmp/reply.fifo", 1000)
  delete out
  message::decode(enc, out)
  assert_eq(out["kind"],       "call",             "message: call kind")
  assert_eq(out["reply_to"],   "/tmp/reply.fifo",  "message: call reply_to")
  assert_eq(out["timeout_ms"], "1000",             "message: call timeout_ms")
}

function test_message_ref_unique(    r1, r2) {
  r1 = message::ref()
  r2 = message::ref()
  assert_true(r1 != r2, "message: ref() is unique")
  assert_true(length(r1) > 5, "message: ref() is non-trivial")
}

function test_message_decode_bad_line(    out) {
  assert_eq(message::decode("not_valid", out), 0, "message: decode bad line = 0")
}

function test_message_make_error_decode(    enc, out) {
  enc = message::make_error("proc://web/0", "proc://cache", "ref123", "Timeout", "timed out")
  delete out
  message::decode(enc, out)
  assert_eq(out["kind"],     "error",    "message: error kind")
  assert_eq(out["selector"], "Timeout",  "message: error selector=error_type")
}
