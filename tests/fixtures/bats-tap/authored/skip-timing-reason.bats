# Lenin's row 7 on #15: a skip whose reason itself ends in a timing. With -T bats prints
# `ok 2 ... in Nms # skip waits in 5ms`, which ends in a timing like a pass does.
@test "passes" { true; }
@test "skipped with a timing in its reason" { skip "waits in 5ms"; }
