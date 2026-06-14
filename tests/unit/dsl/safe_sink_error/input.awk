function non_empty(s: Str) -> NonEmptyStr {
  classify: validator
  return s
}

function handler() {
  let raw   ?= ctx.req.form("title")
  let valid  = raw |> non_empty()
  return ctx.res.html(valid)
}
