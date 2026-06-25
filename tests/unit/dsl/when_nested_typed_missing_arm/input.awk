type ErrA = Error
type ErrB = Error

function fetch_user(ctx) -> Result<Str, Error> {
}

function save_user(user) -> Result<Str, ErrA | ErrB> {
}

function handler(ctx,    user, saved) {
  when fetch_user(ctx) of
    ok user:
      when save_user(user) of
        ok saved:
          return ctx.res.text(saved)
        ng e<ErrA>:
          return ctx.res.status(409)
      end
    ng outer:
      return ctx.res.status(500)
  end
}
