type S = Str & Result<Str, ParseError>

function handler(x: S) {
  ctx.res.json(x |> ctx.res.json())
}
