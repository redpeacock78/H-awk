type Page = Dict<Str, Str>

function handler(ctx) {
  let page: Page = {}
  let r: Response = ctx.res.html(page["body"])
}
