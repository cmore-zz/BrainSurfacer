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

## 2026-08-04 — live context and onscreen entity APIs

- The SDK exposes `RelevantEntities` update and removal operations, but the
  public `AppEntityContext` surface in this seed provides only the
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
