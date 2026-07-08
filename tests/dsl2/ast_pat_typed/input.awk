function run() -> Void {
  when result of
    ok v:
      return v
    ng e<NotFoundError>:
      return ""
  end
}
