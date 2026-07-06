function handler(x: Int) -> Response {
  if (x > 0) {
    print "positive"
  }
  return ctx.res.html(safe.html.escape("ok"))
}
