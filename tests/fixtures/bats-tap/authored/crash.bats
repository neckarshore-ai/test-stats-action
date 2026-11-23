@test "first" { true; }
@test "second kills the run" { kill -9 $PPID; }
@test "third" { true; }
