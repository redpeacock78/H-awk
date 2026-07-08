@namespace "app"
function handler(x) -> Response {
  x = lookup()
  ok x:
    pass()
}
