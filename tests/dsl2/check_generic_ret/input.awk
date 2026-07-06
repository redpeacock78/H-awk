function handler(ctx, s) {
  let r: Result<Int, JsonParseError|JsonTypeError|JsonTooDeepError> = json.decode<Int>(s)
}
