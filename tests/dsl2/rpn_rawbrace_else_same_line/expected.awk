function handler(x) {
  if (x > 0) {
    print "pos"
  } else {
    print "nonpos"
  }
  return ctx::dispatch("res.text", "done")
}
