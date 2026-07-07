function fetch_user(id) -> Result<Str, AuthError> {
}

function handler() {
  when fetch_user(id) of
    default:
      return ctx.res.status(500)
    ok user:
      return ctx.res.json(user)
  end
}
