function f(raw: Untrusted<Str>) -> Response {
  when raw |> option.some() of
    some x:
      return ctx.res.html(x)
    none:
      return ctx.res.text("none")
  end
}
