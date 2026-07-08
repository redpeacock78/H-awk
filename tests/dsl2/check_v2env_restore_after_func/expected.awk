function handler(s) {
  return s
}

BEGIN {
  ctx::dispatch("res.text", s)
}
