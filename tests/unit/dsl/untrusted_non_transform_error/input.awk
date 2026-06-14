function escape_html(s: Str) -> Str {
  classify: sanitizer
  return s
}

function handler() {
  let raw ?= ctx.req.form("title")
  let safe = raw |> escape_html()
}
