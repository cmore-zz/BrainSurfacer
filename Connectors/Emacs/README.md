# BrainSurfacer for Emacs

`brainsurfacer.el` is a single-file global minor mode that reports live
document context to a running BrainSurfacer app. It sends only absolute file
paths grouped as selected, visible, or open; it never sends buffer contents.

## Install

Add this directory to `load-path`, then enable the mode:

```elisp
(add-to-list 'load-path "/path/to/BrainSurfacer/Connectors/Emacs")
(require 'brainsurfacer)
(brainsurfacer-mode 1)
```

The Xcode application build embeds the connector helper at:

```text
BrainSurfacer.app/Contents/Helpers/brainsurfacer-context
```

By default the package examines the process table only after a debounced editor
change, finds a running executable at
`Some Name.app/Contents/MacOS/BrainSurfacer`, and derives the helper path from
that bundle. Both successful and unsuccessful discovery are cached for ten
seconds. BrainSurfacer must already be running, so an ordinary buffer change
does not launch the app.

For an unusual installation, set `brainsurfacer-command` to an absolute helper
path or executable name. Set `brainsurfacer-require-running-app` to `nil` only
if editor activity should be allowed to launch BrainSurfacer.

## What is reported

The default `brainsurfacer-buffer-predicate` accepts file-visiting buffers
derived from `org-mode` or `markdown-mode`, regardless of extension. The
snapshot assigns each eligible file its highest current relevance:

- **selected:** the selected editor window;
- **visible:** other ordinary windows on visible frames;
- **open:** remaining eligible file-visiting buffers.

The connector reacts to file visits, major-mode and visited-file changes,
buffer closure, buffer-list changes, window selection/content/configuration,
frame changes, server visits, and focus changes. Hooks restart a 250 ms debounce
timer; one complete snapshot is collected after the burst. A heartbeat refreshes
unchanged state before its 60-second TTL expires. Disabling the mode or exiting
Emacs clears the provider.

Context eligibility does not override BrainSurfacer indexing policy. For
example, a `.txt` buffer in `org-mode` can be reported as editor context, but it
does not thereby become enrolled or indexed. Until BrainSurfacer can resolve it
through the opted-in catalog, it remains unresolved and cannot affect ranking
or opening.

Indirect buffers use their base buffer's file. Org Agenda, capture buffers, and
other non-file views are intentionally omitted from this first document-level
connector; reporting their underlying heading/task anchors is a later slice.

Run `M-x brainsurfacer-diagnose` to see the discovered app/helper, the current
snapshot, the last send time, and any helper error. Run
`M-x brainsurfacer-report-now` to clear discovery cache and force an update.

## Test

```sh
emacs --batch -Q -L Connectors/Emacs \
  -l brainsurfacer-tests -f ert-run-tests-batch-and-exit
```

The tests cover mode semantics, selected/visible/open classification, payload
bounds, JSON shape, helper path parsing, discovery caching, and hook lifecycle.
