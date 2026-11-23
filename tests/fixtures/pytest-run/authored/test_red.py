# A failure, a strict XPASS (pytest reports it as failed) and a fixture error: all red.
import pytest

def test_pass():
    assert True

def test_fail():
    assert False

@pytest.mark.xfail(reason="should still fail", strict=True)
def test_xpass_strict():
    assert True

@pytest.fixture
def broken():
    raise RuntimeError("fixture setup fails")

def test_error(broken):
    assert True
