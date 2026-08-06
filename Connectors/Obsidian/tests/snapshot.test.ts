import assert from "node:assert/strict";
import test from "node:test";
import {
  buildSnapshot,
  encodePayload,
  maximumDocumentCount,
  maximumPathBytes,
  normalizedTimeToLive,
} from "../src/snapshot";

test("snapshot assigns each path its highest relevance", () => {
  const snapshot = buildSnapshot([
    { path: "/notes/open.md", selected: false, visible: false },
    { path: "/notes/visible.md", selected: false, visible: true },
    { path: "/notes/selected.md", selected: true, visible: true },
    { path: "/notes/open.md", selected: false, visible: true },
    { path: "/notes/selected.md", selected: false, visible: false },
  ]);

  assert.deepEqual(snapshot, {
    selected: ["/notes/selected.md"],
    visible: ["/notes/open.md", "/notes/visible.md"],
    open: [],
  });
});

test("snapshot bounds document count in relevance order", () => {
  const documents = Array.from({ length: 120 }, (_, index) => ({
    path: `/notes/${String(index).padStart(3, "0")}.md`,
    selected: index === 119,
    visible: index >= 100,
  }));
  const snapshot = buildSnapshot(documents);
  const paths = [...snapshot.selected, ...snapshot.visible, ...snapshot.open];

  assert.equal(paths.length, maximumDocumentCount);
  assert.equal(snapshot.selected[0], documents[119]?.path);
});

test("snapshot bounds UTF-8 path bytes", () => {
  const snapshot = buildSnapshot(
    Array.from({ length: 120 }, (_, index) => ({
      path: `/notes/${String(index).padStart(3, "0")}-${"é".repeat(80)}.md`,
      selected: false,
      visible: false,
    })),
  );
  const paths = [...snapshot.selected, ...snapshot.visible, ...snapshot.open];

  assert.ok(
    paths.reduce((total, path) => total + Buffer.byteLength(path, "utf8"), 0)
      <= maximumPathBytes,
  );
});

test("snapshot stops at the byte budget without admitting lower relevance", () => {
  // selected + visible already fill the budget; the shorter open path must not
  // slip in behind them just because it happens to fit the remaining bytes.
  const selectedPath = `/${"s".repeat(9_999)}`;
  const visiblePath = `/${"v".repeat(9_999)}`;
  const openPath = `/${"o".repeat(4_999)}`;
  const snapshot = buildSnapshot([
    { path: selectedPath, selected: true, visible: false },
    { path: visiblePath, selected: false, visible: true },
    { path: openPath, selected: false, visible: false },
  ]);

  assert.deepEqual(snapshot, {
    selected: [selectedPath],
    visible: [],
    open: [],
  });
});

test("payload contains grouped paths and normalized TTL without note content", () => {
  const payload = encodePayload("md.obsidian.test", 600, {
    selected: ["/notes/selected.md"],
    visible: [],
    open: ["/notes/open.md"],
  });

  assert.deepEqual(JSON.parse(payload), {
    providerID: "md.obsidian.test",
    timeToLive: 300,
    selected: ["/notes/selected.md"],
    visible: [],
    open: ["/notes/open.md"],
  });
  assert.equal(normalizedTimeToLive(-10), 1);
  assert.equal(normalizedTimeToLive(Number.NaN), 60);
});
