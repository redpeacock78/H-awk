function f() -> Str {
  when ctx.req.json() of
    foo x:
      return "x"
    default:
      return "d"
  end
}
