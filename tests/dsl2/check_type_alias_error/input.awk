type AuthError = Error
type NotFoundError = Error

function fetch_user(id: Str) -> Result<Str, AuthError|NotFoundError> {
  return
}

function handler() {
  when fetch_user("u1") of
    ok user:
      return
    ng e<AuthError>:
      return
    ng e<NotFoundError>:
      return
  end
}
