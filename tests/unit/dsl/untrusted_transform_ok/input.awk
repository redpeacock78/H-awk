function trim(s: Str) -> Str {
  classify: transform
  return s
}

function non_empty(s: Str) -> Str {
  classify: validator
  return s
}

function handler() {
  let raw ?= ctx.req.form("title")
  let t   = raw |> trim()
  let v  ?= t   |> non_empty()
}
