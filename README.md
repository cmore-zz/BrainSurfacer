# BrainSurfacer

Surface your second brain to macOS.

BrainSurfacer is a native macOS 27+ utility that makes opted-in Markdown and
Org-mode knowledge available to Spotlight, Siri, Apple Intelligence, and App
Intents. The filesystem remains the source of truth; BrainSurfacer is neither an
editor nor a second knowledge database.

The product has two distinct jobs:

1. Turn durable plain-text structure into editor-independent knowledge entities.
2. Contribute ephemeral editor context—what is visible and what is nearby—
   without confusing it with permanent indexing.

Apple frameworks are integration surfaces, not the domain model. Core Spotlight,
App Intents, and future semantic APIs live behind replaceable adapters so the app
can adopt new platform capabilities without redesigning parsing, plugins, or
entity identity.

## Current state

This repository contains an early, architecture-first prototype:

- `BrainSurfacerModel`: platform-neutral entities and source anchors.
- `BrainSurfacerCore`: indexing, catalog, working-set, and opener ports.
- `BrainSurfacerFilesystem`: source documents and an initial Markdown/Org outline
  parser.
- `BrainSurfacerApple`: the macOS 27 App Intents/Core Spotlight projection.
- `BrainSurfacerApp`: a native SwiftUI app for enrolling security-scoped source
  directories, monitoring indexing, manually reindexing, and searching the
  resulting Spotlight content and live editor context.

The app currently persists opted-in directories and lets each source choose
both its content depth and whether discovery stays inside BrainSurfacer or also
enrolls the source with Spotlight and Siri. It recursively scans Markdown and
Org files, parses notes/headings/tasks with bounded section bodies, summaries,
tags, links, planning dates, hierarchy, and precise source ranges, and submits
them through the App Intents/Core Spotlight adapter. A versioned, rebuildable
catalog keeps
entity membership and pending idempotent index mutations across launches, and
reconciles canonical identity across ordinary edits, duplicate headings,
renames, file moves, and uniquely identifiable source-root moves. Org IDs,
CUSTOM_ID values, and Markdown block/attribute IDs are retained as preferred
identity evidence. The App Entity query supports Spotlight-requested partial and
full reindexing. Documents are projected with the macOS 27 Notes schema,
including tag and containing-folder entities; entities without an honest schema
match remain custom. Projection versions trigger a controlled Spotlight rebuild
when their shape changes.
Per-file modification-time and size fingerprints avoid reparsing unchanged
documents across launches. Reconciliation retains the last-known-good entities
for unreadable or malformed files, retries them on the next pass, and removes
entities only after a complete source enumeration confirms deletion. A parser
output revision invalidates cached fingerprints after parsing behavior changes;
same-size edits that deliberately preserve modification time remain a known
metadata-fingerprint limitation.
Individual documents can opt out inside valid Markdown front matter with
`brainsurfacer-index: false`, or in the Org preamble with
`#+BRAINSURFACER_INDEX: false`. Opted-out files emit no searchable entities and
remain excluded until their resource fingerprint changes.
The Index view merges the durable local catalog with Spotlight’s ranked
user-query API, so local-only sources remain searchable without being donated
to Apple. Results open through the same canonical resolution path as Spotlight
and Siri App Intents. Durable `brainsurfacer://` links survive source moves
recorded by the catalog. The app can route results to the default macOS application,
Obsidian with a Markdown heading, or Emacs with a line and column, with safe
fallback to the default application. A system in-app search intent opens the
same Index UI and query flow. A versioned command-line bridge now accepts
complete, expiring selected/visible/open document snapshots from local editor
connectors. Only anchors under enrolled sources are accepted; the snapshots
remain in memory, rerank matched local results, and appear in an App
Entity-annotated Live Context view. A single-file
[Emacs connector](Connectors/Emacs/README.md) now reports file-visiting Org and
Markdown selected, visible, and open buffers through the helper embedded in the
app bundle; deeper Org heading/Agenda context and the Obsidian reporter remain
ahead, as does an authenticated streaming transport. See
[Live editor context](Docs/EDITOR_CONTEXT.md) for the connector contract and
privacy boundary. SDK-specific findings are recorded in
[Platform probes](Docs/PLATFORM_PROBES.md).

## Build

Requires Xcode 27 and the macOS 27 SDK.

```sh
swift build
swift test
```

For a normal macOS application bundle, open `BrainSurfacer.xcodeproj`, select
the shared **BrainSurfacer** scheme and **My Mac**, then Run. The Swift package
remains the source of the library modules and command-line test workflow; the
Xcode application target supplies the launchable `.app`.
Its build also embeds `brainsurfacer-context` under `Contents/Helpers` for local
editor connectors.

See [Architecture](Docs/ARCHITECTURE.md) for the reconciled design and
[Roadmap](Docs/ROADMAP.md) for the next vertical slices.
