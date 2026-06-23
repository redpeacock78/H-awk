type Todo = {
  id: Str
  title: Str
  done: Bool
}

function run() -> Response {
  let todo: Todo = {
    id: "1"
    title: "buy milk"
    done: false
  }
  return ctx.res.json(todo)
}
