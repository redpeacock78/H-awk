BEGIN {
  hawk::dispatch("csrf.token", "abc")
  hawk::dispatch("csrf.token.verify", "abc")
  ctx::dispatch("req.form", "title")
}
