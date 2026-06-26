@namespace "app"
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
