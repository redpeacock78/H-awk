type JsonParseError = Error

function f() -> Str {
  when ctx.req.json() of
    ok v:
      return "ok"
    default:
      return "d"
    ng e<JsonParseError>:
      return "e"
  end
}
