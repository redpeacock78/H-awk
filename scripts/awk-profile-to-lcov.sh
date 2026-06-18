#!/usr/bin/env bash
# Convert gawk --profile output to LCOV format.
# Usage: scripts/awk-profile-to-lcov.sh <profile.out> [source.awk]
# ponytail: single-file SF: only — gawk profile has no per-file metadata
set -e
PROF="${1:?Usage: $0 <profile.out> [source.awk]}"
SF="${2:-hawk.awk}"

gawk -v sf="$SF" '
BEGIN { print "SF:" sf; lf = 0; lh = 0 }
{
  # NR = profile output line number, not source line number.
  # gawk --profile reformats code; line numbers are approximate.
  if (match($0, /^[\t ]*([0-9]+)[ ]*\t/, arr)) {
    count = arr[1] + 0
    print "DA:" NR "," count
    lf++
    if (count > 0) lh++
  }
}
END {
  print "LF:" lf
  print "LH:" lh
  print "end_of_record"
}
' "$PROF"
