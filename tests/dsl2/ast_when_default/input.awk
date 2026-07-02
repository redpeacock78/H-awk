function run() -> Void {
  when x of
    ok v:
      return v
    default:
      return 0
  end
}
