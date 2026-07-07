function f(raw: Str) -> Result<Int, JsonParseError|JsonTypeError|JsonTooDeepError> {
  return raw |> json.decode<Int>()
}
