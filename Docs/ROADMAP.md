# Roadmap

## 0. Platform probes

- Build a Spotlight query CLI that emits broad result attributes as JSON.
- Compare Apple Notes, unmodified Markdown files, Core Spotlight items, and
  `IndexedEntity` projections using canary content.
- Test lexical and semantic queries, deletion, reindex requests, ranking, and
  deep-link opening.
- Record observed behavior and SDK version; do not turn observations into core
  model assumptions.

## 1. First useful vertical slice

- Add and revoke security-scoped source directories. *(Enrollment UI and
  persisted bookmarks implemented.)*
- Enumerate `.md` and `.org` files. *(Initial recursive scan implemented.)*
- Parse notes and headings with stable identifiers and diagnostics. *(Initial
  outline parser and per-file diagnostics implemented.)*
- Incrementally project them through the Apple adapter. *(Full-source projection
  implemented; filesystem change observation remains.)*
- Show indexing status and failures in the app. *(Counts, progress, failures,
  and manual reindex implemented.)*
- Open a result in a configurable application at the closest supported anchor.

## 2. Correctness and scale

- FSEvents-backed change batches and rename handling.
- Durable fingerprints and a disposable entity catalog.
- Full Markdown and Org structure, including links, properties, tasks, blocks,
  and attachments.
- Backpressure, cancellation, bounded parallel parsing, and performance tests
  over tens of thousands of notes.

## 3. Context connectors

- Evolve the in-process `ContextProvider` contract into a versioned local
  connector transport.
- Implement Emacs visible/working-set reporting and precise open targets.
- Add Obsidian after the lifecycle, consent, and expiry semantics are proven.
- Evaluate on-screen entity annotations and interaction donation independently
  from permanent indexing.
