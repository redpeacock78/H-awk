type Todo = {
  done: Bool
}

function a() -> Str {
  let todo: Todo = { done: false }
  todo.done = true
  return "ok"
}

function b() -> Str {
  let todo: Todo = { done: true }
  todo.done = false
  return "x"
}
