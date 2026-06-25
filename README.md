# BrainSurfacer

Surface your second brain to Spotlight.

BrainSurfacer is an exploratory macOS utility for making plain-text knowledge
systems feel native to Apple's semantic search and assistant infrastructure.
The core idea is not merely to index files on disk. It is to expose the user's
active thinking: visible notes, open buffers, current workspace context, and the
paths back into the tools where that thinking actually lives.

## Motivation

Markdown, Org, and similar systems are excellent personal knowledge substrates,
but they often appear to macOS as ordinary files. Meanwhile, apps such as Apple
Notes can participate more deeply in Spotlight, semantic search, Siri, App
Intents, and system-level retrieval.

BrainSurfacer aims to bridge that gap for tools that may never build deep native
macOS integrations themselves, especially cross-platform apps, Electron apps,
terminal/editor workflows, and plain folder-based knowledge bases.

## Product Shape

BrainSurfacer should eventually provide a native macOS surface for:

- Searching opted-in second-brain directories.
- Surfacing currently visible documents from editors and viewers.
- Surfacing broader working context, such as open tabs, buffers, panes, projects,
  vaults, or recently active notes.
- Opening results back into the owning or configured application.
- Providing separate "open to edit" and "open to view" actions where possible.
- Exposing structured entities and actions to Spotlight, Siri, and App Intents.

The first version can be intentionally small: configure a directory, index
Markdown or Org content into Core Spotlight, and open matches in the configured
application.

## Plugin Model

Longer term, BrainSurfacer should support plugins or connectors for specific
knowledge tools. Plugins should describe the user's context and provide ways
back into the source application. They should not own the system indexing policy.

Likely plugin responsibilities:

- Report what is visible now.
- Report the broader current working context.
- Discover source directories, vaults, projects, notebooks, or workspaces.
- Export text, HTML, metadata, headings, tags, links, and other structure.
- Open a surfaced item for editing.
- Open a surfaced item for viewing.

The core app should own:

- User consent and privacy boundaries.
- Core Spotlight indexing.
- App Intents and Siri integration.
- Ranking and freshness policy.
- Deduplication against file-system indexing where possible.
- Cross-plugin schema evolution.

## Conceptual API Sketch

```swift
protocol BrainSurfacerPlugin {
    var id: String { get }
    var displayName: String { get }

    func visibleNow() async throws -> [SurfacedContext]
    func workingContext() async throws -> [SurfacedContext]
    func discoverSources() async throws -> [SurfacedSource]

    func openToEdit(_ target: SurfacedTarget) async throws
    func openToView(_ target: SurfacedTarget) async throws
}
```

The distinction between visible and working context matters:

- Visible context is what the user is looking at right now.
- Working context includes adjacent open buffers, tabs, panes, recent files,
  linked notes, and active project state.

That distinction can feed ranking. A visible note should generally rank above an
open-but-background note, which should rank above a merely indexed archival file.

## Semantic Shape

BrainSurfacer should explore both layers of Apple's public integration surface:

- `CSSearchableItem` and rich `CSSearchableItemAttributeSet` metadata for
  Spotlight search.
- `IndexedEntity` and App Intents entities for structured semantic objects.

A surfaced note or context item might include:

- Title and display name.
- Plain text and optional HTML representation.
- Source URL or file path when one exists.
- Vault, folder, project, or notebook container metadata.
- Headings, tags, links, aliases, and frontmatter.
- Freshness and ranking hints based on active context.
- Typed entities such as people, places, dates, files, URLs, topics, and projects.

Entity resolution should support progressive enrichment. A mention such as
"Alice" may initially be indexed as raw text or an app-defined weak entity, then
later resolve to a Contact-backed `IntentPerson` if the user grants Contacts
access or confirms the match.

## Early Exploration

Before committing to architecture, BrainSurfacer should learn how macOS 27's
Spotlight semantic index behaves in practice.

Useful probes:

- Create rich Apple Notes with known canary phrases, people, dates, links, and
  concepts.
- Query Spotlight through `CSUserQuery` with semantic search enabled and disabled.
- Fetch broad result attributes to inspect how Apple Notes appears to third-party
  query clients.
- Compare default Markdown file behavior out of the box.
- Index richer BrainSurfacer items for selected directories and see whether they
  can effectively supplement or outrank default file indexing.

The first tool may simply be a command-line Spotlight probe that dumps query
results as JSON. That gives the project facts before it grows an app shell.

## Privacy Posture

BrainSurfacer should be explicit and conservative:

- Only index opted-in sources.
- Keep enrichment local unless the user enables a plugin or service that does
  otherwise.
- Make it clear which apps, directories, and context providers are active.
- Prefer scoped permissions over broad access.
- Treat "currently visible" and "working context" as sensitive.

The project has a slightly clinical, brain-surgery-flavored name, but the product
should feel trustworthy: a local bridge from personal knowledge tools to native
macOS retrieval, not a black box that leaks private notes.
