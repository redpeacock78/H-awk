function f(s: Str) -> Result<Int, JsonError> {
  return json.decode<Int>(s)
}
