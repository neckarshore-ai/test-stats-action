# Lenin's table on planning #4209 (2026-11-22): pass, xfail, non-strict XPASS count; skip does not.
import pytest

def test_pass():
    assert True

@pytest.mark.xfail(reason="known")
def test_xfail():
    assert False

@pytest.mark.xfail(reason="fixed meanwhile", strict=False)
def test_xpass_nonstrict():
    assert True

@pytest.mark.skip(reason="not on this host")
def test_skip():
    assert True
