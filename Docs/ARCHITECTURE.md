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
    ├── BrainSurfacerFilesystem ──> BrainSurfacerModel
    └── BrainSurfacerApple ──> BrainSurfacerCore ──> BrainSurfacerModel
```

Dependencies only point inward. Filesystem, Apple frameworks, editor protocols,
and UI can be replaced independently.

## Layers

### Model

`KnowledgeEntity` is the canonical editor-independent representation. An entity
has a stable application identifier, kind, title, optional body and summary,
tags, links, relationships, and a source anchor that can return the user to a
file, heading, and line.

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

The included `OutlineParser` only proves the boundary with Markdown and Org
headings. It is not the production parser.

### Core

Core coordinates source replacement as a single logical mutation:

1. parse one changed source;
2. stage that source's intended catalog state and durable index mutation;
3. replay any older pending index mutations in order;
4. upsert new/changed entities and remove stale identifiers;
5. acknowledge the mutation only after the permanent index accepts it.

The production catalog is a versioned, rebuildable JSON projection in
Application Support. It preserves source membership, canonical entities,
provider-local references, and pending index mutations across launches. A
mutation is idempotent and remains pending after an adapter failure or process
crash, so startup recovery can replay it without losing stale deletions. The
in-memory catalog remains available for focused tests and transient tools.

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

The initial Apple adapter projects a `KnowledgeEntity` into an `IndexedEntity`
and calls `CSSearchableIndex.indexAppEntities`. It can be replaced by multiple
schema-specific entity projections later.

In-app search goes back through the `EntitySearch` port. The Apple adapter uses
`CSUserQuery` for ranked lexical and semantic results and filters on a
BrainSurfacer App Entity domain, so only opted-in knowledge donations are
returned. Core and the UI do not construct Spotlight predicates.

The macOS 27 `IndexedEntityQuery` adapter resolves identifiers from the durable
catalog. It handles partial reindex requests by restoring known entities and
deleting requested identifiers that no longer resolve; a full request rebuilds
the BrainSurfacer entity type from the catalog. This remains a projection of the
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
