@namespace "app"
function outer() {
  return 1
}

function middle(x) {
  return x
}

function inner(x) {
  return x
}

function handler(ctx,    a, b, c) {
  when outer() of
    ok a:
      when middle(a) of
        ok b:
          when inner(b) of
            some c:
              return ctx.res.text(c)
            none:
              return ctx.res.status(404)
          end
        ng e1:
          return ctx.res.status(500)
      end
    ng e0:
      return ctx.res.status(502)
  end
}
