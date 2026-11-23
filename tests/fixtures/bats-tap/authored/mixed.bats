@test "a passes" { true; }
@test "b is skipped" { skip "not on this host"; }
@test "c fails" { false; }
@test "d passes" { true; }
