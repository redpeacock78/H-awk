function non_empty(s: Str) -> NonEmptyStr {
  classify: validator
  if (length(s) == 0) error("empty")
  return s
}

function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let validated = raw |> non_empty()
  return ctx.res.text(validated)
}
