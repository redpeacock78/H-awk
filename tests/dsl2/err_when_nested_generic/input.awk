function fetch() -> Result<Dict<Str, Int>, AuthError|NotFoundError> {
  return
}

function handler() {
  when fetch() of
    ok body:
      return
    ng e<AuthError>:
      return
  end
}
