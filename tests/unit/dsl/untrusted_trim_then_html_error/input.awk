function trim(s: Str) -> Str {
  classify: transform
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
  return s
}

function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let trimmed = raw |> trim()
  return ctx.res.html(trimmed)
}
