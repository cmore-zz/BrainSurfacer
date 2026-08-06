import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import {
  HelperDiscovery,
  parseRunningApplications,
  type DiscoveryEnvironment,
} from "../src/discovery";

test("process parser preserves app bundle paths containing spaces", () => {
  assert.deepEqual(
    parseRunningApplications([
      "  100 /Applications/Other.app/Contents/MacOS/Other",
      " 4242 /Users/test/Build Products/BrainSurfacer Debug.app/Contents/MacOS/BrainSurfacer -flag yes",
    ]),
    [{
      pid: 4242,
      bundlePath: "/Users/test/Build Products/BrainSurfacer Debug.app",
    }],
  );
});

test("negative discovery is cached during the cooldown", async () => {
  let processCalls = 0;
  const environment = makeEnvironment({
    processLines: async () => {
      processCalls += 1;
      return [];
    },
  });
  const discovery = new HelperDiscovery({
    environment,
    cooldownMilliseconds: 10_000,
  });

  assert.equal(await discovery.discover(), null);
  assert.equal(await discovery.discover(), null);
  assert.equal(processCalls, 1);
});

test("stale running process invalidates positive discovery immediately", async () => {
  const bundle = "/Build Products/BrainSurfacer.app";
  const helper = path.join(
    bundle,
    "Contents",
    "Helpers",
    "brainsurfacer-context",
  );
  let processCalls = 0;
  let running = true;
  const environment = makeEnvironment({
    processLines: async () => {
      processCalls += 1;
      return processCalls === 1
        ? [` 4242 ${bundle}/Contents/MacOS/BrainSurfacer`]
        : [];
    },
    isProcessRunning: () => running,
    isExecutable: async (candidate) => candidate === helper,
  });
  const discovery = new HelperDiscovery({ environment });

  assert.equal((await discovery.discover())?.command, helper);
  running = false;
  assert.equal(await discovery.discover(), null);
  assert.equal(processCalls, 2);
});

function makeEnvironment(
  overrides: Partial<DiscoveryEnvironment>,
): DiscoveryEnvironment {
  return {
    now: () => 1_000,
    processLines: async () => [],
    isProcessRunning: () => true,
    isExecutable: async () => false,
    ...overrides,
  };
}
