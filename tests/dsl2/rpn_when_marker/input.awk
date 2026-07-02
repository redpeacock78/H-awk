function run() -> Void {
  when r of
    ok v:
      return v
    ng _:
      return ""
  end
}
