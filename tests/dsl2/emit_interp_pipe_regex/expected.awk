function handler(x,    m) {
  m = sprintf("%s", x~/a|>b/)
  return ctx::dispatch("res.text", m)
}
