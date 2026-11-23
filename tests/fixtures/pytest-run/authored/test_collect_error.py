# A module that cannot be imported: pytest reports a collection error and runs nothing from it.
import module_that_does_not_exist  # noqa: F401

def test_never_collected():
    assert True
