function Status(val) { if (type::accepts("Int|Str", val)) return val; return result_ng("TypeError:Status", "expected Int|Str, got " val) }

function run() {
  return ctx::dispatch("res.text", "ok")
}
