# Architecture

## Product boundary

BrainSurfacer is a local semantic knowledge provider for macOS. It indexes
user-approved Markdown and Org-mode sources, exposes useful structure to system
services, accepts transient context from editors, and opens results back in the
user's chosen tool.

It does not edit notes, replace Spotlight, own canonical content, or maintain a
parallel embedding database. Derived caches are disposable and rebuildable from
the source files.

## Reconciled model

The initial README and the product brief agree on the destination. This design
makes four distinctions explicit:

1. **Source documents are inputs, not entities.** A file may produce a note,
   headings, tasks, projects, people, links, and relationships.
2. **Permanent knowledge and live context have different lifecycles.** Parsed
   entities are indexed until their source changes or disappears. Visible and
   working-set entities expire quickly and only affect relevance/context.
3. **Plugins report context; core owns policy.** Editor connectors may discover
   sources, report visible/adjacent items, and open targets. They do not write
   directly to Spotlight or choose global ranking.
4. **Apple APIs are adapters.** The semantic model never conforms to
   `AppEntity`, stores `CSSearchableItemAttributeSet`, or assumes today's App
   Intents schema is permanent.

## Dependency direction

```text
BrainSurfacerApp
    ├── BrainSurfacerCore ──> BrainSurfacerModel
    ├── BrainSurfacerFilesystem ──> BrainSurfacerCore ──> BrainSurfacerModel
    └── BrainSurfacerApple ──> BrainSurfacerFilesystem
                └────────────> BrainSurfacerCore ──> BrainSurfacerModel
```

Dependencies only point inward. The filesystem layer owns enrolled-source
bookmark persistence, refresh, and access leases; the Apple layer composes
those leases with platform openers instead of implementing a second bookmark
reader.

## Layers

### Model

`KnowledgeEntity` is the canonical editor-independent representation. An entity
has a stable application identifier, kind, title, optional body and summary,
tags, links, structured source dates, relationships, and a source anchor that
can return the user to a file, heading, line range, and UTF-8 byte range.

The first model uses an extensible `kind` enum and typed relationships. This is
intentionally less specific than Apple's schema domains. As evidence
accumulates, richer value types can be added without changing parser or storage
contracts wholesale.

### Filesystem

The filesystem layer owns security-scoped source access, enumeration, change
detection, parsing, fingerprints, and disposable parse caches. Parsers return
semantic entities and diagnostics. They must retain enough source structure to
support headings, hierarchy, tags, links, timestamps, TODO states, properties,
source blocks, and attachments.

The included `OutlineParser` indexes a document plus Markdown and Org outline
entities. A section body contains only prose before its first child or sibling
heading; child prose belongs to the child entity and is not duplicated into its
ancestors. The source anchor separately spans the complete section subtree so
an opener can select the closest meaningful source range. Searchable document
and section bodies are UTF-8-safely bounded at 512 KiB and 64 KiB respectively,
summaries are bounded at 240 characters, Markdown heading depth follows
CommonMark's six-level limit, and Org nesting is bounded at 32 levels.
Truncation is explicit entity metadata. Document tags are inherited by section
entities for search recall. Org property drawers and
planning lines, and Markdown front matter, contribute identity, tags, or dates
without polluting section prose. The representative parser corpus locks these
policies down while broader syntax coverage remains future work.

### Core

Filesystem reconciliation and Core coordinate one enrolled root as a logical
mutation:

1. load that root's persisted per-file resource fingerprints and exact catalog
   membership;
2. parse files whose modification date or size changed and reuse catalog
   entities for unchanged files;
3. retain last-known-good entities and the older fingerprint when a file cannot
   be read or parsed, so the file is retried;
4. remove a file's entities only when a complete enumeration confirms that the
   file is absent;
5. replay older pending index mutations, then stage and apply the reconciled
   root replacement;
6. persist the new fingerprints only after the catalog and permanent index
   accept that replacement.

The fingerprint cache is separately versioned, disposable JSON in Application
Support. Each fingerprint includes the parser-output revision as well as file
modification date and size, so parser changes invalidate otherwise-unchanged
files. Missing, invalid, or unwritable fingerprint state causes reparsing rather
than catalog deletion or a false indexing failure. Catalog recovery also
reparses because an empty recovered catalog has no entities eligible for reuse.

Modification date and size avoid reading unchanged files, but they can miss an
in-place, same-size edit made by a tool that also preserves the timestamp. This
is an explicit performance tradeoff for the first incremental slice; content
hashing or event-provided change knowledge can close that gap later. FSEvents
now observes every enrolled root with per-file and root-change notifications.
Each running stream holds the roots' security-scoped read leases and releases
them when the observed enrollment set is replaced or the app model is torn
down.
It maps a changed path to every enclosing enrolled source, preserving correct
behavior for overlapping roots, and treats dropped event history as requiring
reconciliation of every observed root. Notifications are debounced into root
batches; changes received during reconciliation schedule one later pass rather
than an overlapping pass. The reconciler uses an explicit single-flight gate
so actor reentrancy cannot interleave startup, manual, enrollment, removal, and
event-driven work across suspension points. FSEvents decides when to reconcile,
while persisted fingerprints still decide which files need parsing, so
rename/delete confirmation and the last-known-good failure contract remain
centralized in the scanner. Bounded parallel parsing can feed the same
reconciler later without changing that contract.

The production catalog is a versioned, rebuildable JSON projection in
Application Support. It preserves source membership, canonical entities,
provider-local references, and pending index mutations across launches. A
mutation is idempotent and remains pending after an adapter failure or process
crash, so startup recovery can replay it without losing stale deletions. The
in-memory catalog remains available for focused tests and transient tools.

If the derived catalog is missing, unreadable, or has an incompatible schema,
the coordinating writer treats it as requiring a full rebuild; invalid bytes
are also quarantined for diagnosis. The coordinator clears the permanent
projection before rebuilding every enrolled source and only then clears the
recovery marker. This prevents catalog recovery from leaving stale platform
records behind. Completing that rebuild also discards pending mutations made
obsolete by the reset and successful all-source projection.
Permanent-index adapters that do not implement full reset support fail recovery
explicitly instead of silently accepting a no-op reset.

The app process owns the catalog's explicit coordinating-writer instance. App
Entity queries use read-only instances: an invalid catalog produces an empty
in-memory snapshot without changing the shared file, leaving quarantine and
rebuild initiation to the app. Atomic file replacement gives readers a complete
old or new snapshot but is not multi-process writer coordination. Any extension
or editor connector that writes catalog state must first add a file lock or move
the catalog to a transactional store such as SQLite.

Ports define the permanent index, entity search, context providers, contextual
publishing, and document opening. No port mentions an Apple framework or
editor.

Live context arrives as replaceable `ContextSnapshot` values. Each contribution
references a canonical entity by entity ID, file, source anchor, or
provider-local identifier and carries a relevance state and expiration. The
`ContextCoordinator` resolves those references through the catalog, combines
signals from multiple providers without duplicating entities, retains unresolved
signals while parsing catches up, and removes expired or disconnected state.

### Apple platform

The Apple adapter routes canonical entities into separate platform projections.
Documents use the macOS 27 Notes `note` schema, with schema-defined properties
for rich name/content, attachments, tags, pin state, dates, and containing
folder. Containing folders and the BrainSurfacer source account use the Notes
`folder` and `account` schemas. Tags are custom App Entities supplied through
the schema-defined `Note.tags` relationship because the current SDK advertises
but does not successfully expand the `notes.tag` schema macro.

Headings and other concepts retain an honest custom `IndexedEntity` projection.
Tasks do too: the semantic model currently lacks the list, due/recurrence,
completion, subtask, flag, and trigger semantics required by the Reminders
schema. A TODO keyword alone is not treated as proof of Reminders semantics.

Schema properties use App Entity `Property` or `ComputedProperty` metadata and
bind structured values to Spotlight indexing keys. Raw
`CSSearchableItemAttributeSet` fields mirror the minimum display, full-text, and
source metadata needed for reliable search and opening; they are no longer the
sole carrier of structured semantics.

Projection schema version `4` is persisted separately from the disposable
catalog. A version change removes every custom and Notes App Entity before the
first new mutation is accepted. Each upsert first removes its platform ID from
both projection types, which also makes a note-to-custom type transition
idempotent. Display summaries and full searchable bodies remain distinct in
both custom and Notes projections: Core Spotlight's content description
receives the summary while its text content receives the body. Schema-specific
`IndexedEntityQuery` implementations service partial
and full Spotlight rebuild requests from the shared durable catalog.

In-app search goes back through the `EntitySearch` port. The Apple adapter uses
`CSUserQuery` for ranked lexical and semantic results and filters on a
BrainSurfacer App Entity domain, so only opted-in knowledge donations are
returned. Core and the UI do not construct Spotlight predicates.

Every persistent projection carries a `brainsurfacer://` content URL containing
its canonical entity identifier; the original source path remains separate
Spotlight metadata. Spotlight results, Open Intents for custom and Notes
entities, direct deep links, and rows in the Index view all resolve that
identifier through `EntityOpeningCoordinator` before dispatch. This prevents a
stale projected path from becoming a second identity system and lets catalog
reconciliation follow moves and renames.

Incoming custom-scheme URLs are untrusted navigation. Handlers accept only the
fixed entity and search routes, never accept filesystem paths or commands, and
resolve entity identifiers exclusively against the enrolled local catalog. An
entity route may still open its resolved source in the configured external
editor, while a search route only presents a query in BrainSurfacer.

The configured macOS opener routes to the file's default application, an
Obsidian URI with the closest Markdown heading, or Emacs.app arguments with the
closest line and column. A failed or stale editor preference falls back to the
system default. Editor-specific probes do not present a system app-picker;
only the terminal default-app path prompts the user if macOS needs help. Before
checking or dispatching a source file, the opener
loads the same configurable enrollment store used by source management,
refreshes stale saved bookmarks, selects the most-specific enrolled parent
directory, and holds its security-scoped access for the complete operation.
This makes the same sandbox permission available to UI and App Intent opens
without keeping source roots permanently active. The system
`ShowInAppSearchResultsIntent`
persists its term long enough for app launch and presents the same
Spotlight-backed Index search UI; an in-process notification handles an
already-running app.

The macOS 27 `IndexedEntityQuery` adapters resolve identifiers from the durable
catalog. They handle partial reindex requests by restoring known entities and
deleting requested identifiers that no longer resolve; a full request replaces
that projection type from the catalog. This remains a projection of the
filesystem rather than a second source of truth.

The SDK also adds `RelevantEntities`, but its public context surface is currently
domain-specific rather than a general “current working set” mechanism. The
architecture therefore does not equate live editor context with
`RelevantEntities`. Working context can feed in-app ranking, suggestions,
donations, and on-screen entity annotations where appropriate while the adapter
evolves with the SDK.

### Plugins and openers

A connector reports:

- visible entities: the primary document, heading, selection, or narrowed tree;
- working-set entities: tabs, buffers, neighbors, recent items, project, task;
- discovered sources, if the editor can identify them;
- opener capabilities and source anchors.

Connectors contribute facts with provenance and freshness. Core applies consent,
deduplication, ranking, expiration, and indexing policy. Openers are separate
capabilities because a source may be indexed from the filesystem and opened in
several applications.

## Identity and storage

Parsers attach identity evidence rather than deciding fallback identity. Org
`ID` values are globally canonical. Org `CUSTOM_ID`, Markdown `^block-id` and
`{#attribute-id}` values, editor identifiers, current structural paths, and
content fingerprints are retained as matching evidence.

The catalog reconciles each parse observation against the previous source
snapshot. It prefers explicit identifiers, then the current observed path, then
structural fingerprints scoped to a matched document. Duplicate fingerprints
are paired by source order only inside that matched document. This preserves
canonical identifiers through ordinary edits, duplicate headings, heading and
file renames, and source-root moves without guessing between ambiguous copies.
Fallback canonical identifiers are deterministic digests of the first observed
parser identifier; the Apple adapter separately applies its own platform length
bound, so platform projection identifiers never become canonical identity.

Fingerprints and mappings remain a disposable cache—not an alternate source of
user knowledge. A cache rebuild can deterministically recover identity at the
current source location, while explicit source identifiers are required to
recover the same identity across both a move and loss of the catalog.

## Privacy and failure behavior

- Index only explicitly approved directories.
- Treat visible and working-set context as more sensitive than durable indexing.
- Keep processing local by default.
- Make every active source and connector visible and revocable.
- If parsing or a platform adapter fails, preserve the source files, record a
  diagnostic, and retry only the affected unit.
- If a newer semantic API is unavailable or unsuitable, degrade to rich Core
  Spotlight metadata and ordinary open actions.

## Architectural tests

Tests should emphasize invariants:

- one source can yield multiple related entities;
- replacing a source removes stale identifiers;
- live context never becomes permanent without explicit policy;
- adapters preserve stable identifiers and source URLs;
- parser failures do not destroy the last known good index;
- opening an entity retains the most precise available source anchor.
