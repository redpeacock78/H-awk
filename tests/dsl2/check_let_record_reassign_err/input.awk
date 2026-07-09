type Todo = {
  id: Str
}

function f() -> Void {
  let t: Todo = { id: "1" }
  t = { id: "2" }
}
