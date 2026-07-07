function handler(x) {
  if (x > 0) {
    print "positive"
  }
  return ctx::dispatch("res.html", safe::dispatch("html.escape", "ok"))
}
