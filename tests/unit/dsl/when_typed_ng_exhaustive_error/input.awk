type AuthError = Error
type NotFoundError = Error

function fetch() -> Result<Str, AuthError | NotFoundError> {
  return AuthError("bad")
}

function handler() {
  when fetch() of
    ok v:
      return ctx.res.json(v)
    ng e<AuthError>:
      return ctx.res.status(401)
  end
}
