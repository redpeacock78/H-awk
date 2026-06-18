function get_count() {
  return 42
}

function handler() -> Response {
  let msg: Str = get_count()
  return ctx.res.text(msg)
}
