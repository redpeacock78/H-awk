@namespace "app"
function lookup() {
  return 1
}

function pass() {
  return 1
}

function inner() {
  return 1
}

function handler(    x) {
  x = lookup()
  when x of
    ok n:
      pass()
    default:
      when inner() of
        ok y:
          pass()
      end
  end
}
