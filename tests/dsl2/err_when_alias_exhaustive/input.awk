type R = Result<Str, AuthError|NotFoundError>

function fetch_user(id: Str) -> R {
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
