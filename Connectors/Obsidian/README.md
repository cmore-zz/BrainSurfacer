# BrainSurfacer for Obsidian

This desktop-only Obsidian plugin reports the Markdown documents that are
selected, visible, or open to a running BrainSurfacer app. It sends absolute
file paths only—never note contents—and each complete snapshot expires after
60 seconds.

## Install for development

From this directory:

```sh
npm install
./install.sh /path/to/your/Obsidian/Vault
```

The installer verifies that the vault has an `.obsidian` configuration
directory, builds the plugin, creates `.obsidian/plugins` when it is absent,
and copies the runtime files to:

```text
Vault/.obsidian/plugins/brainsurfacer-live-context/
  main.js
  manifest.json
```

It refuses to replace a non-directory at either plugin path. Re-run the same
command to update an existing installation; local plugin settings in
`data.json` are left untouched.

Then reload Obsidian, disable Restricted Mode if necessary, and enable
**BrainSurfacer Live Context** under Community plugins. This first slice is a
repository-local development plugin; it has not been submitted to Obsidian's
community directory.

## What is reported

- **selected:** the file in the active Markdown view;
- **visible:** Markdown files displayed in other visible panes or popout
  windows;
- **open:** Markdown files in background tabs, including deferred tabs that
  remain unloaded.

A file receives only its highest relevance. The plugin uses Obsidian's public
Markdown-leaf and view-state APIs, coalesces workspace changes for 250 ms, and
refreshes unchanged state every 30 seconds. It reacts to active-leaf,
file-open, layout, popout-window, rename, and deletion events. Disabling the
plugin or quitting Obsidian clears its provider on a best-effort basis; the TTL
removes it if shutdown cleanup cannot run.

Each vault uses a stable provider identifier derived from a truncated hash of
its local root path, so simultaneous vaults replace only their own snapshots.
Only local filesystem vaults are supported.

## Helper discovery

The plugin scans full local process commands for a running
`*.app/Contents/MacOS/BrainSurfacer`, then uses that bundle's embedded helper:

```text
BrainSurfacer.app/Contents/Helpers/brainsurfacer-context
```

Positive and negative discovery is cached for ten seconds. A cached positive
result retains the app process ID and validates that it is still alive before
reuse. Every helper invocation targets the discovered bundle explicitly, so a
DerivedData build does not accidentally hand the update to another registered
copy. Obsidian activity never launches BrainSurfacer.

An absolute helper path can be configured under **Settings → BrainSurfacer Live
Context**. The plugin still requires a running BrainSurfacer app so it can
target the correct bundle. Automatic discovery assumes the local process table
is trustworthy; it does not perform a code-signature identity check.

Use the command palette action **BrainSurfacer Live Context: Report live
context now** to clear discovery cache, force a report, and show a diagnostic
notice.

## Test

```sh
npm test
npm run build
```

The tests cover relevance deduplication, deterministic bounds, UTF-8 path-byte
accounting, TTL normalization, process parsing, negative discovery caching, and
stale-process invalidation.

Context eligibility does not grant indexing authority. BrainSurfacer accepts
only files already resolvable under an enrolled source, and a local-only source
remains withheld from Spotlight and Siri projections.
