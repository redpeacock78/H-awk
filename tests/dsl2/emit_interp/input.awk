function handler() -> Response {
  let id = "todo-42"
  let title = "Buy milk"
  let msg = "todo #{id}: #{title}"
  return ctx.res.text(msg)
}
