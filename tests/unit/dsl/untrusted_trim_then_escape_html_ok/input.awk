function trim(s: Str) -> Str {
  classify: transform
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
  return s
}

function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let trimmed = raw |> trim()
  let safe = trimmed |> safe.html.escape()
  return ctx.res.html(safe)
}
