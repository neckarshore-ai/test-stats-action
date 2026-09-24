// Authored suite for test-stats-action's playwright-json handler: every count
// reading (expected / expected+flaky / total-skipped / total) yields a different number.
import { test, expect } from "@playwright/test";
test("passes 1", () => { expect(1).toBe(1); });
test("passes 2", () => { expect(2).toBe(2); });
test("passes 3 (expected failure via test.fail)", () => { test.fail(); expect(1).toBe(2); });
test("flaky: fails first attempt, passes on retry", ({}, info) => { expect(info.retry).toBe(1); });
test("fails deterministically", () => { expect("red").toBe("green"); });
test.skip("skipped 1", () => {});
test.fixme("skipped 2 (fixme)", () => {});
