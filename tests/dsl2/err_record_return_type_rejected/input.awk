type Todo = { id: Str }
function make_todo() -> Todo {
  let t: Todo = { id: "x" }
  return t
}
function h() {
  let t: Todo = make_todo()
  return ctx.res.json(t)
}
