function fetch_user(id: Str) -> Result<Str, AuthError|NotFoundError> {
  return
}

function handler() {
  when fetch_user(id) of
    ok user:
      return
    ng e<AuthError>:
      return
  end
}
