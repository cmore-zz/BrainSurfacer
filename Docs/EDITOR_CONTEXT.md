# Live editor context

BrainSurfacer can receive a short-lived snapshot of the documents an editor has
selected, visible, or open. That context reranks results already matched by an
in-app search; it does not add unrelated results, enroll new sources, or create
a permanent Spotlight projection.

## Connector bridge

The Swift package includes an initial `brainsurfacer-context` command-line
bridge for editor integrations:

```sh
swift run brainsurfacer-context \
  --provider org.gnu.Emacs \
  --selected /path/to/selected.org \
  --visible /path/to/visible.md \
  --open /path/to/another.org
```

Each document flag may be repeated. Relative paths are resolved against the
connector's working directory. `--ttl` selects an expiration in seconds; the
default is 60 seconds and the maximum is 300. Sending the provider with no
document flags clears its current snapshot:

```sh
swift run brainsurfacer-context --provider org.gnu.Emacs
```

For larger working sets, pass one JSON file instead of placing every path on the
command line:

```json
{
  "providerID": "org.gnu.Emacs",
  "timeToLive": 60,
  "selected": ["notes/plan.org"],
  "visible": ["notes/plan.org", "notes/research.md"],
  "open": ["notes/plan.org", "notes/research.md", "notes/reference.org"]
}
```

```sh
swift run brainsurfacer-context --input /path/to/context.json
```

The three path arrays are optional, and relative paths resolve against the
directory containing the JSON file. `--input -` reads the same bounded JSON from
standard input and resolves relative paths against the current working
directory, avoiding a temporary file. Input is bounded to 64 KiB in both modes.
JSON input cannot be combined with `--provider`, `--ttl`, or the individual
document flags. `--print-url` remains available in either mode.

This is a replacement protocol, not an event log. A connector should resend
the complete current snapshot after its visible buffers, tabs, or selection
changes and periodically while that state remains current. Provider identifiers
should be stable and specific to the connector.

For development and protocol inspection, `--print-url` prints the handoff URL
without opening BrainSurfacer.

The macOS application target builds the same helper implementation and embeds
it at `BrainSurfacer.app/Contents/Helpers/brainsurfacer-context`, giving editor
connectors a stable path in installed, renamed, and Xcode Debug app bundles.

## Emacs connector

The initial Emacs package is a single
[`brainsurfacer.el`](../Connectors/Emacs/brainsurfacer.el) global minor mode. It
uses the editing mode—not the filename extension—to accept file-visiting
buffers derived from `org-mode` or `markdown-mode`. The selected editor window,
other windows on visible frames, and remaining eligible buffers become the
selected, visible, and open groups respectively.

File visits, major-mode and visited-file changes, buffer closure, window/frame
state, server visits, and focus changes schedule a complete snapshot through a
short debounce. JSON is written directly to the helper's standard input. A TTL
heartbeat preserves unchanged context, while disabling the mode or exiting
Emacs clears it.

By default the package scans full process command lines for a running
`*.app/Contents/MacOS/BrainSurfacer`, derives that bundle's helper path, and
caches positive or negative discovery for ten seconds. It does nothing while
the app is absent. An explicit helper setting and opt-in launch-on-context mode
cover unusual installations. See the
[Emacs connector guide](../Connectors/Emacs/README.md) for setup, customization,
diagnostics, tests, and current limitations.

Editor context and indexing remain separate decisions. A file opened in
`org-mode` can be reported even when its extension is not currently parsed, but
the connector cannot enroll or index it. It remains unresolved unless the
BrainSurfacer catalog already contains a canonical entity for that source.

## Consent and lifetime

- A snapshot carries source anchors and relevance labels, never document
  contents.
- BrainSurfacer accepts only local file URLs under a currently enrolled source.
  Paths outside those sources are ignored and reported in Live Context.
- Snapshots are held in memory, replace prior state from the same provider, and
  expire automatically. They are not written to the entity catalog or donated
  as permanent App Entities.
- An empty snapshot or disconnect removes a provider immediately.
- The protocol is versioned and bounded to 100 documents and 16 KiB of decoded
  path text per update.

The initial bridge encodes its JSON payload with URL-safe base64 and delivers
it through the local `brainsurfacer:` Launch Services route. Base64 is not
encryption, and this transport does not authenticate the sending process. The
enrollment check, strict size and lifetime limits, and absence of commands or
content keep its authority narrow. A packaged connector should eventually use
an authenticated streaming IPC transport; the versioned snapshot model can
remain the payload contract.

The interim transport treats provider identifiers and relevance claims as
unverified connector input. A local process can temporarily populate Live
Context and influence the order of already-matching in-app results, but cannot
add search results, enroll or open arbitrary paths, or change permanent
indexing. BrainSurfacer caps active providers at 16 and evicts the oldest when
that limit is reached. These controls primarily bound malformed or noisy
connectors; the design does not claim to contain hostile code already executing
as the logged-in user.

## Apple API boundary

BrainSurfacer annotates the entity rows in its own Live Context view with the
same App Entity identifiers used for Spotlight. This lets the system associate
visible BrainSurfacer UI with canonical entities where the OS supports onscreen
entity awareness.

Those annotations cannot describe windows owned by Emacs or Obsidian. In the
current macOS 27 SDK, `RelevantEntities` does not expose a general document
working-set context: its public context is limited to domain-specific cases such
as now-playing audio. An editor-native connector is therefore still required to
observe that editor's selected, visible, and open documents. BrainSurfacer uses
the resulting context locally without claiming that Apple can see or infer the
originating editor window.
