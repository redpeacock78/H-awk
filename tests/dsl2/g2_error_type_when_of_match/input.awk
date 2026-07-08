type AuthError = Error

function f(x: Int) -> Result<Int, AuthError> {
  if (x < 0) {
    return AuthError("negative")
  }
  return result_ok_make(x)
}

function handler() -> Response {
  when f(1) of
    ok v:
      return ctx.res.text("ok")
    ng e<AuthError>:
      return ctx.res.status(401)
  end
}
