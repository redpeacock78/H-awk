function handler(    id, title, msg) {
  id = "todo-42"
  title = "Buy milk"
  msg = sprintf("todo %s: %s", id, title)
  return ctx::dispatch("res.text", msg)
}
