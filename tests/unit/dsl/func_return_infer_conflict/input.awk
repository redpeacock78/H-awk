function ambiguous() {
  if (1) return "hello"
  return 42
}

function handler() -> Response {
  let msg: Str = ambiguous()
  return ctx.res.text(msg)
}
