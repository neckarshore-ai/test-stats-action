# Lenin's finding on #15: bats 1.14.0 does not escape # in a test name, so a passing test whose
# name carries "# skip" and a skipped test print the same text without --timing (-T).
@test "name with # skip inside" { true; }
@test "plain" { skip; }
@test "skip with reason" { skip "because"; }
@test "x # skip y" { true; }
@test "x" { skip "y"; }
