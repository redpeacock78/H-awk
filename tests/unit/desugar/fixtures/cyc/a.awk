@include "b.awk"
BEGIN { if (0) cyc_a() }
function cyc_a() { return 1 }
