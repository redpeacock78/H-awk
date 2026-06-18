function ambiguous() {
  if (1) return "hello"
  return 42
}

function handler(    msg) {
  msg = ambiguous()
  return ctx::dispatch("res.text", msg)
}
