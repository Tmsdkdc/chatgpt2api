# 0003: Preserve Studio history across reloads

Status: pending-verification

- Owner: Studio conversation persistence runtime
- Created: 2026-11-11
- Updated: 2026-11-11
- Related ADR: [0002](../adr/0002-studio-uses-asynchronous-image-tasks.md)

## Problem and user outcome

Reference images were serialized as Base64 into localStorage with all messages.
Two references to a roughly 2.1 MiB PNG reproduced QuotaExceededError: six
visible messages became four after reload. Server Image Assets remained intact.
The user requested a fix preserving existing history and images, publication to
the Fork, and commands for their existing server deployment.

## Scope and non-goals

Migrate browser history to IndexedDB, retain the legacy keys, serialize writes,
protect loading and unsaved navigation, and expose retryable failures. Remove
automatic conversation/message trimming. No server history synchronization,
account/authentication change, backend storage migration, or Sub2API change.

## Language, ownership and Interfaces

Image Tasks and Image Assets retain their owners from CONTEXT.md and ADR 0002.
Studio conversation presentation remains browser-local. The existing
conversation persistence runtime owns loading, saving, retries and cleanup;
its IndexedDB adapter owns database transactions. Studio renders readiness and
errors, and keeps the existing layout/scroll owners. Backend Interfaces do not
change. Native IndexedDB avoids adding dependencies or a second durable owner.

## Persistence, concurrency and failure behavior

An atomic, schema-versioned snapshot includes conversations, original reference
images, active ID and notices. Migration commits before editing is enabled and
does not remove legacy localStorage keys. Queued saves retain the latest state;
only transaction completion confirms success. Failed writes retain the last
committed snapshot and pending data for retry. Read failure blocks empty-state
initialization. Ordinary unload is guarded while writes are pending; forced
browser termination cannot be guaranteed. No secrets or real user data enter
tests or commits. Multi-tab merging and cross-device synchronization are outside
scope; this fixes the reported single-tab workflow.

## Acceptance and verification matrix

| Criterion | Evidence | Status |
| --- | --- | --- |
| Legacy messages/reference pixels/active ID/notices survive migration, old keys unchanged | Isolated Chrome with real PNG and production runtime | passed |
| A snapshot over 10 MiB survives reload | Native IndexedDB in isolated Chrome | passed |
| Failed save/migration preserves committed/legacy state and retry succeeds | Transaction-abort injection | passed |
| Corrupt stored history is not overwritten by an empty conversation | Isolated Chrome | passed |
| Burst writes and histories beyond old limits preserve first and last messages | Production runtime; 82 conversations and 201 messages | passed |
| Long conversations restore newer result images using bounded requests | Production console; 360 messages, 180 tasks, at most 100 IDs per request | passed |
| Referencing completed images, editing, reload and failure UI work on desktop/mobile | Production console with mocked task API, 1366px/390px | passed |
| Local production build and Fork update-channel policy | Console build; 11 policy tests; 12 reload scenarios | passed |
| Published release bundle and container image | GitHub release checks | pending |
| Actual server deployment and user history | User executes update and verifies existing browser | pending |

## Documentation, ADR and rollback

CHANGELOG, frontend/system maps and the Studio history runbook document this
change. No new ADR is required: ADR 0002's browser-local conversation ownership
and server-side task truth remain unchanged. Server rollback uses the existing
backup script. An old frontend only reads the retained pre-migration localStorage
snapshot; do not mistake it for the latest IndexedDB history or clear site data.
