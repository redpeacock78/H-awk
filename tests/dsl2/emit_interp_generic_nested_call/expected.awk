function f(s) {
  return sprintf("%s", sprintf("%s", json::dispatch("decode_t", "Dict<Str,Int>", s)))
}
