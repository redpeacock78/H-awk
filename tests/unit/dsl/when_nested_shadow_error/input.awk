@namespace "app"
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
