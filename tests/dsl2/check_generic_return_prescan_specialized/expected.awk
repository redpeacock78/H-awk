function decode(s) {
  return json::dispatch("decode_t", "Int", s)
}
function run(    r) {
  r = decode(env::dispatch("get", "X"))
  return ctx::dispatch("res.text", "ok")
}
