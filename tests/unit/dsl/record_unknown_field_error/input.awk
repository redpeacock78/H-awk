type Todo = {
  id: Str
}

function run() -> Response {
  let todo: Todo = { id: "1" }
  todo.unknown = "x"
  return ctx.res.json(todo)
}
