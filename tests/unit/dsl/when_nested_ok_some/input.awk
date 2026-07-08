@namespace "app"
function fetch_user(x) {
  return x
}

function find_name(x) {
  return x
}

function handler(ctx,    user, name) {
  when fetch_user(ctx) of
    ok user:
      when find_name(user) of
        some n:
          return ctx.res.text(n)
        none:
          return ctx.res.status(404)
      end
    ng e:
      return ctx.res.status(500)
  end
}
