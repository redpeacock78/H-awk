function get_cached(key: Str) -> Effect<Option<Str>> {
  return option.none()
}

function handler() {
  let val ?= get_cached("foo")
  return ctx.res.text(val)
}
