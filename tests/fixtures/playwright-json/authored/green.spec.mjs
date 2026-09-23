// Authored suite: all tests pass, but globalTeardown throws — the run is red while stats show 0 unexpected.
import { test, expect } from "@playwright/test";
test("passes 1", () => { expect(1).toBe(1); });
test("passes 2", () => { expect(2).toBe(2); });
