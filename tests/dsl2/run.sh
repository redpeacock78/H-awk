#!/bin/bash

PASS=0
FAIL=0

for case_dir in tests/dsl2/*/; do
  case_name=$(basename "$case_dir")
  input_file="$case_dir/input.awk"
  expected_file="$case_dir/expected.awk"

  if [ ! -f "$input_file" ] || [ ! -f "$expected_file" ]; then
    continue
  fi

  output=$(LC_ALL=C gawk -b -f dsl/v2/main.awk "$input_file" 2>&1)
  expected=$(cat "$expected_file")

  if [ "$output" = "$expected" ]; then
    ((PASS++))
  else
    echo "FAIL: $case_name" >&2
    echo "expected:" >&2
    echo "$expected" >&2
    echo "got:" >&2
    echo "$output" >&2
    ((FAIL++))
  fi
done

printf "%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
