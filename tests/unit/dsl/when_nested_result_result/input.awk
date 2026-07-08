@namespace "app"
function fetch_user(x) {
  return x
}

function save_user(x) {
  return x
}

function handler(ctx,    user, saved) {
  when fetch_user(ctx) of
    ok user:
      when save_user(user) of
        ok saved:
          return ctx.res.text(saved)
        ng inner:
          return ctx.res.status(409)
      end
    ng outer:
      return ctx.res.status(500)
  end
}
