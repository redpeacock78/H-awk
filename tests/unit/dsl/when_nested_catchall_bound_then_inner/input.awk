@namespace "app"
function handler(    x) {
  x = lookup()
  when x of
    ok n:
      pass()
    default err:
      when inner() of
        ok y:
          pass()
      end
  end
}
