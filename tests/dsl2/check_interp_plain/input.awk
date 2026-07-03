function handler(ctx, first, last) {
  let msg = "#{first} #{last}"
  ctx.res.text(msg)
}
