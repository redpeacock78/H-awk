function run() -> Void {
  when result of
    ok v:
      return v
    ng <AuthError>:
      return ""
  end
}
