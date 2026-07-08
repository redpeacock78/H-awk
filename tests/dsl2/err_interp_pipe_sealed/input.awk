function handler(body: Str) -> Response {
  return ctx.res.html(safe.html.raw("#{json.decode(body) |> json.encode()}"))
}
