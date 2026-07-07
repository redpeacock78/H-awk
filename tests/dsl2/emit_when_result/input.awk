function fetch_user(id) -> Result<Str, AuthError | NotFoundError> {
}

function handler() {
  when fetch_user(id) of
    ok user:
      return ctx.res.json(user)
    ng e<AuthError>:
      return ctx.res.status(401)
    ng e<NotFoundError>:
      return ctx.res.status(404)
    default:
      return ctx.res.status(500)
  end
}
