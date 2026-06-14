function escape_html(s: Str) -> Safe<HtmlStr> {
  classify: sanitizer
  return s
}

function non_empty(s: Str) -> NonEmptyStr {
  classify: validator
  return s
}

function handler() {
  let raw    ?= ctx.req.form("title")
  let valid   = raw    |> non_empty()
  let safe    = valid  |> escape_html()
  return ctx.res.html(safe)
}
