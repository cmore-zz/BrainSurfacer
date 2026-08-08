import assert from "node:assert/strict";
import test from "node:test";
import { helperArguments } from "../src/transport";

test("helper targets the exact running BrainSurfacer process", () => {
  assert.deepEqual(
    helperArguments({
      pid: 4242,
      bundlePath: "/Build Products/BrainSurfacer Debug.app",
      command: "/Build Products/BrainSurfacer Debug.app/Contents/Helpers/brainsurfacer-context",
    }),
    [
      "--process",
      "4242",
      "--application",
      "/Build Products/BrainSurfacer Debug.app",
      "--input",
      "-",
    ],
  );
});
