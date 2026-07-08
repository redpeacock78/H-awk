function pred(b: Int) -> Bool {
  return b > 0
}
function f(a: Bool, b: Int) -> Bool {
  return a && (b |> pred())
}
