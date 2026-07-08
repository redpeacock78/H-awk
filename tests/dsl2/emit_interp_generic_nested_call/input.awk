function f(s: Str) -> Str {
  return "#{sprintf("%s", json.decode<Dict<Str,Int>>(s))}"
}
