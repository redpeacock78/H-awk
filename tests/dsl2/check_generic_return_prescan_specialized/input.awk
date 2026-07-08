function decode(s: Str) { return json.decode_t("Int", s) }
function run() -> Response {
  let r = decode(env.get("X"))
  return ctx.res.text("ok")
}
