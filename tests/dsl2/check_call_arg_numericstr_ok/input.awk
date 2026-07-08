function normalize(text: Str) -> Str {
  return text
}
function handler() {
  return ctx.res.text(normalize("1"))
}
