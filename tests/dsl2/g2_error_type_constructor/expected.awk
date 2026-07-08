function AuthError(msg) { return result_ng("AuthError", msg) }

function f(x) {
  if (x < 0) {
  return AuthError("negative")
  }
  return result_ok_make(x)
}
