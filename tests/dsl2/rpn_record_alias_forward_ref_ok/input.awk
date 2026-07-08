function run() -> Response {
  let t: TodoAlias = { id: "1" }
  return ctx.res.json(t)
}

type Todo = {
  id: Str
}
type TodoAlias = Todo
