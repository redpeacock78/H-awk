type Ints = List<Int>

function handler(ctx) {
  let xs: Ints = []
  xs["bad"] = "oops"
}
