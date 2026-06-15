function handler(    id, title, msg) {
  id = type::coerce("42", "Str")
  title = "Buy milk"
  msg = sprintf("todo %s: %s", id, title)
  return ctx::dispatch("res.text", msg)
}
