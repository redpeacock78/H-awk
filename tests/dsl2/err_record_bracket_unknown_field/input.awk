type Todo = { id: Str }
function h() {
  let t: Todo = { id: "x" }
  t["nope"] = 1
  return ctx.res.json(t)
}
