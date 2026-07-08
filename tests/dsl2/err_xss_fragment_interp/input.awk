function handler() -> Response {
  return ctx.res.html(safe.html.fragment("<p>#{env.get("USER")}</p>"))
}
