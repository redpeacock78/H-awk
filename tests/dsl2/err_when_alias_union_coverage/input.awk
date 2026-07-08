type Errors = AuthError|NotFoundError

function f(r: Result<Str, Errors>) -> Str {
  when r of
    ok v: return v
    ng e<AuthError>: return "auth"
  end
}
