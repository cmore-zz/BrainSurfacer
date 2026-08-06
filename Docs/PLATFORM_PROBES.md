# Apple platform probes

These observations are tied to an SDK build. They are implementation evidence,
not promises about a later macOS seed.

## 2026-08-01 — Xcode 27.0 (27A5194q), macOS 27 SDK (26A5353p)

### App schema projections

- `@AppEntity(schema: .notes.note)`, `.notes.folder`, and `.notes.account`
  compile and produce App Intents metadata in the BrainSurfacer application.
- The Note schema requires rich `name` and `content` values, attachments, tags,
  pin state, creation/modification dates, and an optional folder. BrainSurfacer
  has honest values for all required fields; unknown values remain empty or
  `nil` rather than being fabricated.
- The SDK Swift interface advertises `.notes.tag`, but the App Intents macro in
  this seed rejects `@AppEntity(schema: .notes.tag)` with `unknownSchema`.
  BrainSurfacer therefore supplies a custom tag App Entity through the
  schema-defined `Note.tags` property. Re-test this on the next SDK seed.
- The Reminders reminder schema requires a list plus reminder-specific fields
  including subtasks, due date, recurrence, completion, flags, and triggers.
  Current Org tasks only supply a title and TODO state, so projecting them as
  Reminders would misrepresent the source. They remain custom indexed entities.
- Containing-folder identifiers are hashes of their standardized filesystem
  paths because the current semantic model does not retain an enrolled-root
  relative folder identity. Notes retain their canonical identity across a root
  move, but the derived folder entity is replaced. Do not adopt `SyncableEntity`
  for these projections until this is resolved and tested across devices.

Relevant Apple documentation:

- [Notes schema](https://developer.apple.com/documentation/appintents/app-schema-domain-notes)
- [Note entity](https://developer.apple.com/documentation/appintents/appschema/notesentity/note)
- [Folder entity](https://developer.apple.com/documentation/appintents/appschema/notesentity/folder)
- [Reminder entity](https://developer.apple.com/documentation/appintents/appschema/remindersentity/reminder)

### Projection lifecycle

The current projection schema version is `4`. When the stored version differs,
the Apple adapter removes all BrainSurfacer custom and Notes App Entities before
accepting the first replacement mutation, then records the version. Every
upsert also removes the same identifier from both projection types before
indexing it, preventing duplicates if a canonical entity changes projection
type.

Version 4 separates concise display descriptions from complete searchable
section text. Custom and Notes projections write `contentDescription` from the
entity summary and `textContent` from its bounded body.

## 2026-08-04 — Xcode 27.0 beta 4 (27A5228h), macOS 27 SDK

### Live context and onscreen entity APIs

- The SDK exposes `RelevantEntities` update and removal operations, but the
  public `AppEntityContext` surface in beta 4 still provides only the
  domain-specific audio now-playing context. It does not provide a general
  selected, visible, or open-document context.
- SwiftUI exposes `appEntityIdentifier(_:)` and `appEntityUIElements`; AppKit
  exposes corresponding App Entity identifier and UI-element providers. These
  APIs annotate UI owned by the adopting process. They do not let BrainSurfacer
  annotate an Emacs or Obsidian window.
- BrainSurfacer therefore annotates resolved rows in its own Live Context view
  with the same identity used by its Spotlight projections. Editor-native
  connectors remain necessary to report the source editor's working set.
- Editor context remains an ephemeral local ranking signal. This probe does not
  establish that `RelevantEntities`, App Entity UI annotations, or permanent
  indexing share lifecycle or privacy semantics.

### Explicit Siri and Shortcuts access

- In beta 4, merely conforming to `ShowInAppSearchResultsIntent` does not mark
  the action as semantically executable by Siri. Adding
  `@AppIntent(schema: .system.searchInApp)` emits the
  `SystemSearchInAppIntent` assistant schema and Assistant Intent system
  protocol in the final app metadata. The older `.system.search` spelling is
  deprecated in this SDK.
- An ordinary read-only `AppIntent` can return an array of custom App Entities
  in the background. Beta 4 metadata records the array output and every declared
  entity property, including content excerpt, source-file URL, relevance,
  provider identifiers, and the BrainSurfacer open URL.
- `TransientAppEntity` marks those returned current-document values as
  transient in extracted metadata. BrainSurfacer uses it so an intent result
  does not turn an expiring editor snapshot into durable system entity state.
- A string-returning read intent accepts the existing Notes-schema entity and
  exposes its content and source path explicitly. This avoids relying on Siri
  to infer that indexed `textContent` may be returned to the user.
- An `AppShortcutsProvider` compiled only in the Swift package dependency emits
  phrases in that package's metadata, but beta 4 does not merge those phrases
  into the app bundle's `autoShortcuts` table. Declaring the provider in the app
  target does. The final app metadata contains both shortcut records.
- App Shortcuts remain phrase-routed custom actions. Beta 4 does not provide a
  system schema for querying an editor's selected, visible, or open documents,
  so the expiring current-context action cannot honestly adopt the search
  schema merely to make Siri call it.
- On macOS 27 beta 4, Siri successfully retrieved durable BrainSurfacer notes
  for a natural-language MBTI query, but did not route “what’s open in
  BrainSurfacer?” to the donated current-context shortcut. The SDK exposes no
  matching Assistant Schema or general current-view entity context for this
  editor state. BrainSurfacer therefore also emits one bounded Core Spotlight
  App Entity describing the current selected/visible/open set. It is limited to
  sources already enrolled in Apple discovery, replaced on every context
  update, deleted when context is empty, and assigned the earliest included
  provider expiration date so it cannot outlive any state it describes.
- On the tested beta 4 seed, `linkd` could not obtain sandbox access to an app
  bundle under Xcode's user DerivedData directory. Siri then logged
  `No ShowInAppSearchResultsIntent registered` even though the final bundle's
  extracted metadata contained the correct schema.
- Copying the same ad-hoc-signed build to `/Applications` removed the filesystem
  denial, but `linkd` rejected it as `not trusted for binding`. End-to-end Siri
  schema testing therefore requires a normally installed build with an Apple
  Development (or distribution) signature; an ad-hoc `Sign to Run Locally`
  build is sufficient for compilation and metadata inspection, but not for
  this binder on the tested seed.
- After installing the Apple Development-signed build, registering that exact
  bundle as developer-trusted, and restarting the per-user `linkd` daemon, beta
  4 accepted the app connection, interpolated its App Shortcuts, and logged that
  it donated them to Siri. During interpolation `linkd` still emitted sandbox
  extension warnings for the app path, but they were nonfatal in this state.
- The beta 4 `SetStoreUpdateService` rejected Indexed Entity donations from
  both Debug and Release Apple Development-signed builds with
  `CSIndexErrorDomain -1000`. Independent signature validation succeeded.
  Adding the standard application/team identifier entitlements caused Xcode to
  embed a development provisioning profile and let the service identify the
  process, but it still rejected the donation as “not properly entitled.” A
  plain Core Spotlight item and an eligible `NSUserActivity` were routed
  through the same failing service, and another third-party app produced the
  same diagnostic. Apple documents no extra capability for `IndexedEntity`;
  this is treated as a seed-specific bridge failure, not as an entitlement to
  guess or request. The signing and fallback experiments are not retained.
- Those service errors were not conclusive for the installed app's effective
  Siri state. After the bounded, expiring current-context entity was installed
  and Emacs refreshed its working set, Siri successfully answered the natural
  “what’s open in BrainSurfacer?” query. Keep the failed-development-donation
  observations as beta diagnostics, but treat the trusted installed-app test as
  the end-to-end result for this seed.
