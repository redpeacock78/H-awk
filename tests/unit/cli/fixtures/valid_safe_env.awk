BEGIN {
  hawk.app.get("/", "handle_index")
}

function handle_index() -> Response {
  let home: Str = env.get("HOME")
  let escaped: HtmlEscapedStr = safe.html.escape(home)
  return ctx.res.html(escaped)
}
