@namespace "app"
function outer() {
  return 1
}

function inner() {
  return 1
}

function handler(    x) {
  x = outer()
  when x of
    ok x:
      when inner() of
        ok x:
          return x
      end
  end
}
