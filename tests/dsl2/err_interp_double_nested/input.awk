function f(s: Str) -> Str {
  return s
}
function handler() {
  let g = "world"
  let msg = "#{f("#{g}")}"
}
