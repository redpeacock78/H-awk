function handler(x: Int) -> Response {
  if (x > 0) {
    print "pos"
  } else {
    print "nonpos"
  }
  return ctx.res.text("done")
}
