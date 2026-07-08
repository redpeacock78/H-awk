function h(v,    n) {
  n = type::coerce(v, "Int")
  return ctx::dispatch("res.status", n)
}
