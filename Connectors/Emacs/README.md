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
seconds. A cached positive result retains the app process ID and checks that it
is still live without rerunning `ps`. BrainSurfacer must already be running, so
an ordinary buffer change does not launch the app. Automatic discovery assumes
the local process table is trustworthy; it does not perform a code-signature
identity check.

Each helper invocation also receives that exact process ID and application
bundle path. The helper sends context through BrainSurfacer’s per-process local
message port, without asking Launch Services to open, activate, or reorder the
application. The bundle path verifies that a cached PID still belongs to the
expected installed or DerivedData build.

For an unusual installation, set `brainsurfacer-command` to an absolute helper
path or executable name. Set `brainsurfacer-require-running-app` to `nil` only
if editor activity should be allowed to launch BrainSurfacer.

## What is reported

The default `brainsurfacer-buffer-predicate` accepts local file-visiting buffers
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
Emacs clears the provider. TTL settings outside BrainSurfacer's supported
1–300-second range are normalized before both reporting and heartbeat
scheduling.

The default provider identifier is `org.gnu.Emacs`. BrainSurfacer's Automatic
document opener recognizes that identifier and dot-suffixed variants such as
`org.gnu.Emacs.work`. Preserve that namespace when customizing
`brainsurfacer-provider-id`; an unrelated identifier still reports context but
cannot select Emacs automatically.

Context eligibility does not override BrainSurfacer indexing policy. For
example, a `.txt` buffer in `org-mode` can be reported as editor context, but it
does not thereby become enrolled or indexed. Until BrainSurfacer can resolve it
through the opted-in catalog, it remains unresolved and cannot affect ranking
or opening.

Indirect buffers use their base buffer's file. Org Agenda, capture buffers, and
other non-file views are intentionally omitted from this first document-level
connector, as are remote/TRAMP files. Reporting underlying heading/task anchors
is a later slice.

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
