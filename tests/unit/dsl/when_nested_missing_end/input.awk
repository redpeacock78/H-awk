@namespace "app"
function handler(    x) {
  x = lookup()
  when x of
    ok y:
      pass()
    ng e:
      fail(e)
}
