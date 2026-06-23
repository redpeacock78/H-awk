type Todo = {
  id: Str
  done: Bool
}

function run() -> Response {
  let todo: Todo = { id: "1", done: false }
  todo.done = "yes"
}
