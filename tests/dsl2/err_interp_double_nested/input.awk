function f(s: Str) -> Str {
  return s
}
function handler() {
  let g = "world"
  let mut msg = "#{f("#{g}")}"
}
