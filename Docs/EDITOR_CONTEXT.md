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

This is a replacement protocol, not an event log. A connector should resend
the complete current snapshot after its visible buffers, tabs, or selection
changes and periodically while that state remains current. Provider identifiers
should be stable and specific to the connector.

For development and protocol inspection, `--print-url` prints the handoff URL
without opening BrainSurfacer.

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
