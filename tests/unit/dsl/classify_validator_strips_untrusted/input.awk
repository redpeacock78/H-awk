function validate_id(s: Str) -> Str {
  classify: validator
  return s
}

function h() -> Response {
  let raw ?= ctx.req.query("id")
  let id = raw |> validate_id()
  return ctx.res.text(id)
}
