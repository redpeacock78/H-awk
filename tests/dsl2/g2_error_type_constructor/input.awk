type AuthError = Error

function f(x: Int) -> Result<Int, AuthError> {
  if (x < 0) {
    return AuthError("negative")
  }
  return result_ok_make(x)
}
