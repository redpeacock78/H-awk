function run() -> Response {
  let todo: Todo = { id: 1 }
  return ctx.res.json(todo)
}

type Todo = {
  id: Int
}
