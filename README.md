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
  resulting Spotlight content.

The app currently persists opted-in directories, recursively scans Markdown and
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
The Index view queries donated entities through Spotlight’s ranked user-query
API. The parser and Apple projection remain deliberate probes rather than final
implementations: filesystem change observation, broader syntax coverage, and
editor connectors are still ahead. SDK-specific findings are recorded in
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

See [Architecture](Docs/ARCHITECTURE.md) for the reconciled design and
[Roadmap](Docs/ROADMAP.md) for the next vertical slices.
