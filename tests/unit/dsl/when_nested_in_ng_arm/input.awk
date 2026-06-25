@namespace "app"
function handler(ctx,    user, fallback) {
  when fetch_user(ctx) of
    ok user:
      return ctx.res.text(user)
    ng outer:
      when recover_user(outer) of
        ok fallback:
          return ctx.res.text(fallback)
        ng inner:
          return ctx.res.status(500)
      end
  end
}
