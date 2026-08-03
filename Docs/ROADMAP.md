# Roadmap

The roadmap is ordered by dependency and risk. Each step should leave a useful,
testable vertical slice; later Apple integrations should build on durable entity
identity and correct index lifecycle rather than compensating for missing core
invariants.

## 1. Durable catalog, mutation journal, and reindexing *(implemented)*

- Persist the disposable entity catalog, source membership, and the state needed
  to reconstruct platform projections across launches.
- Journal intended Spotlight changes before applying them and acknowledge them
  only after the index accepts the complete idempotent mutation.
- Replay pending mutations at startup and before accepting newer changes.
- Resolve App Entity identifiers from the durable catalog.
- Adopt `IndexedEntityQuery` so Spotlight can request partial or complete
  reindexing.
- Preserve a clear schema version and rebuild path for all derived state.

## 2. Stable entity identity *(implemented)*

- Prefer Org `ID` and `CUSTOM_ID`, Markdown block IDs, and editor-native IDs.
- Add durable structural matching for content without explicit identifiers.
- Handle duplicate headings, heading renames, file moves, and source-root moves.
- Keep canonical IDs distinct from bounded platform projection IDs.
- Adopt `SyncableEntity` only after identifiers are demonstrably stable across
  devices.

## 3. Schema-aware Apple projections *(implemented)*

- Project documents through the macOS 27 Notes schema where the semantics fit.
- Add schema-aware tag and folder entities.
- Project tasks through the Reminders schema only when required task semantics
  are known; otherwise retain an honest custom task entity.
- Use indexed App Entity properties for structured fields and reserve raw
  Spotlight attributes for supplementary metadata.
- Version projections so schema changes can trigger a controlled rebuild.

## 4. Section content and precise source anchors *(implemented)*

- Parse bounded section bodies rather than indexing heading titles alone.
- Retain heading paths, byte/line ranges, parent documents, tags, links, dates,
  and relationships.
- Separate concise display summaries from full searchable text.
- Define size, nesting, and child-section policies using a representative
  Markdown and Org corpus.

## 5. Open and in-app search actions *(implemented)*

- Add an App Intent open action for every persistent entity.
- Route durable entity deep links through configurable Emacs, Obsidian, and
  `NSWorkspace` openers while preserving the closest supported anchor.
- Add a system in-app search intent that presents BrainSurfacer's search UI.
- Make Spotlight, Siri, and in-app results share one resolution and opening
  path.

## 6. Incremental, failure-safe filesystem reconciliation *(in progress)*

- Observe source roots with FSEvents and coalesce rename/change batches. *(implemented)*
- Persist file fingerprints and parse only changed units. *(implemented)*
- Replace whole-catalog JSON reloads with indexed, transactional lookup once
  query scale or additional writer processes require it.
- Retain the last-known-good projection for unreadable or malformed files;
  remove entities only for confirmed deletions. *(implemented)*
- Add cancellation, backpressure, bounded parallel parsing, and scale tests over
  tens of thousands of notes. *(implemented)*

## 7. Privacy, enrollment, and protected indexes

- Add per-source include/exclude patterns and source-level indexing modes.
- Support document metadata that explicitly opts content out of indexing.
- Separate Spotlight/Siri enrollment from BrainSurfacer-local discovery.
- Evaluate protected Core Spotlight indexes and make every derived copy visible
  and revocable.
- Report exactly what was indexed, skipped, retained after failure, or deleted.

## 8. Semantic and App Intents evaluation

- Build a canary corpus and query CLI that records SDK/OS versions and broad
  result attributes.
- Test lexical and semantic retrieval, paraphrases, negative queries, deletion,
  rename, relaunch, reindex requests, ranking, and deep-link opening.
- Add AppIntentsTesting coverage for entity resolution and actions.
- Evaluate result coverage for Foundation Models plus `SpotlightSearchTool`
  before adding an assistant-style product surface.

## 9. Context consumers and editor connectors

- Wire `ContextCoordinator` into BrainSurfacer-local reranking and suggestions.
- Evolve the in-process provider contract into a versioned local transport.
- Implement Emacs and Obsidian visible/working-set reporting and precise opener
  capabilities.
- Keep editor context ephemeral and consented; do not imply that it becomes
  Apple onscreen awareness when the editor itself cannot annotate its views.
- Evaluate interaction donation and future general-purpose relevant-entity
  contexts independently from permanent indexing.

## Platform probes that continue throughout

- Compare Apple Notes, unmodified Markdown files, ordinary Core Spotlight
  items, and schema-aware `IndexedEntity` projections using canary content.
- Record observed behavior instead of turning beta SDK behavior into core model
  assumptions.
- Revisit quotas, protection classes, hydration, and supported schema domains on
  every macOS 27 seed used for development.
