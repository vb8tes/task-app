# Sisyphus — Technical Context

## What This Is

Sisyphus is a Kanban-style task management web app with a Greek mythology theme. It is deployed, live, and has real user data.

The naming convention maps the mythology throughout: tasks are "Boulders," columns are "Mountains", boards are "Worlds," completing a task is reaching the "Summit," undoing completion is "It Rolled Back," and deleting a task is "Drop It." 

The app supports multiple boards per user, each with multiple columns, each column with active and completed task lists. Drag-and-drop works for tasks, columns, and boards. Contextual video animations play on task completion, deletion, and undo.

## Tech Stack

- Single `index.html` file (~3200 lines), no build step
- Vanilla JS using ES modules (no framework)
- Firebase Auth with Google sign-in (popup with redirect fallback)
- Firestore for persistence and real-time sync
- Deployed on Vercel
- Montserrat font via Google Fonts
- Google Analytics (gtag)
- Firebase project: `mysisyphus-xyz`
- GitHub repo: `vb8tes/task-app`

## Code Structure

Everything lives in one file, organized top to bottom as follows.

**CSS (~940 lines):** Custom properties in `:root` for typography, surfaces, and drag-and-drop styling. Styles for login screen, loading overlay, top bar, settings panel, sidebar with board list, columns, task cards, card buttons, completed divider, add-column button, modal, and drop zones.

**HTML body:** Three background video elements (rollback, crushed, summit animations). Sidebar with board list nav and "New World" button. Modal overlay for confirm/prompt/alert dialogs. Login screen with Google sign-in. Loading screen. Top bar with board name label, tagline, user avatar, sign-out button, and settings panel. Board container with "New Struggle" add-column button.

**Script block (~2270 lines):** A single `<script type="module">` containing all application logic, organized in these sections:

1. **Firebase init** — imports, config, app/auth/db/provider setup
2. **State variables** — `currentUser`, `activeBoardId`, `boardList`, `boardStoreCache`, `savePromise`, drag state, listener references
3. **Tooltip system** — custom tooltip with delay, positioning, mouse-follow behavior
4. **Custom modal** — promise-based modal replacing native alert/confirm/prompt (supports alert, confirm, prompt types)
5. **Utility helpers** — `createEntityId`, `isDesktopBrowser`, `buildVersionStamp`, version fetching from GitHub API
6. **Task subcollection helpers** — `tasksCollectionRef(boardId)`, `taskDocRef(boardId, taskId)`
7. **Fractional ordering** — base-26 lexicographic string keys (`orderKeyBetween`, `generateOrderKeyBeforeAll`, `generateOrderKeyAfterAll`)
8. **Animation system** — video playback for task completion/deletion/undo, respects user preference toggle
9. **Settings** — animations toggle, version display
10. **Sidebar** — expand/collapse, scroll position sync, board list rendering with drag-and-drop reordering
11. **Firestore save/load** — `boardStoreRef`, localStorage caching layer, `collectBoardColumns` (metadata only), `persistBoardColumns`, `commitSaveNow`, `saveBoard` (debounced), `flushPendingSave`
12. **Board management** — `createBoardMeta`, `persistBoardsIndex`, `renameBoard`, `reorderBoardList`, `deleteBoardList`, `createTaskList`
13. **Task migration** — `migrateUserTasksIfNeeded` (one-time legacy-to-subcollection migration)
14. **Surgical DOM updaters** — `renderTaskAdded`, `renderTaskModified`, `renderTaskRemoved`
15. **Task snapshot listener** — `subscribeTasksForBoard` using `onSnapshot` with `docChanges()`
16. **Board store snapshot listener** — `subscribeBoardStore` for board list and column metadata sync
17. **Board loading** — `loadBoard`, `switchToBoard`, `initializeBoards`
18. **Column and task card creation** — `createColumnElement`, `createTaskCard` (with stable `taskId` and `orderKey` on DOM elements)
19. **Action functions** — `addTask`, `toggleDone`, `deleteTask`, `deleteColumn`, `addColumn`, `beginInlineTaskEdit`
20. **Auth handlers** — sign-in, sign-out, `onAuthStateChanged`, `beforeunload`

## Architecture

### Task data (subcollection model)

Each task is an individual Firestore document:

```
Path:  users/{uid}/boards/{boardId}/tasks/{taskId}
Shape: { id, text, columnId, done, orderKey, createdAt }
```

- `id` — stable Firestore doc ID, never changes even if task text changes
- `text` — mutable task content (max 500 chars)
- `columnId` — which column the task belongs to
- `done` — boolean completion state
- `orderKey` — lexicographic string for sort position within a column
- `createdAt` — server timestamp

Action functions write directly to individual task documents. The DOM is updated optimistically (immediately on user action), then the `onSnapshot` listener confirms or corrects via `docChanges()`.

### Column/board metadata (legacy model)

Board and column structure is stored in a single document:

```
Path:  users/{uid}/board/data
Shape: { boards, columnsByBoard, columnsMetaByBoard, tasksMigrated }
```

- `boards` — array of `{ id, name, profile }` objects (the board index)
- `columnsByBoard` — map of boardId to array of `{ id, name }` column metadata
- `columnsMetaByBoard` — map of boardId to `{ updatedAt, dirty }` sync metadata
- `tasksMigrated` — boolean flag indicating legacy migration is complete

This document is written via the debounced `saveBoard()` → `commitSaveNow()` → `persistBoardColumns()` path. Changes are infrequent (column rename, column reorder, board operations).

### Real-time sync

Two snapshot listeners run simultaneously:

1. **Board store listener** (`subscribeBoardStore`) — watches the single metadata document for board list changes and column structure changes. If columns are added/removed/renamed remotely, it re-renders empty column shells and re-subscribes the task listener.

2. **Task listener** (`subscribeTasksForBoard`) — watches the tasks subcollection for the active board, ordered by `orderKey`. Routes each `docChange` to `renderTaskAdded`, `renderTaskModified`, or `renderTaskRemoved` for surgical DOM updates. No full re-renders.

### Fractional ordering

Task order within a column uses lexicographic base-26 string keys (a–z). The `orderKeyBetween(before, after)` function computes a midpoint key between any two bounds. New tasks prepended to a column get a key before all existing keys. Moved tasks get a key after all existing keys in the target list. Default key length is 5 characters (~11.8M slots).

### localStorage caching

A localStorage layer caches column metadata per-user for offline resilience and fast initial render. Tasks bypass this layer entirely — they are always read from Firestore via the snapshot listener.

## Considerations and Concerns

**Migration idempotency.** The `migrateUserTasksIfNeeded` function runs once per user, guarded by the `tasksMigrated` flag. If a browser crashes mid-migration, the next login re-runs it. The function uses `setDoc` (upsert semantics) so re-runs overwrite identical data without creating duplicates. Do not remove this function or the flag check.

**Column metadata save guard.** The `if (!savePromise)` guard in `subscribeBoardStore` prevents remote column metadata from overwriting a local save in flight. This guard is still necessary and correct for column operations.

**beforeunload.** Only flushes column metadata (`commitSaveNow` without task serialization). Task writes are per-action and already persisted before the page closes.

**Firestore security rules.** The rules must include the tasks subcollection path. The `isValidBoardStore` validation must allow `columnsMetaByBoard` (map) and `tasksMigrated` (bool) fields alongside the original `boards`, `columnsByBoard`, and `columns` fields.

**OrderKey exhaustion.** Repeatedly inserting between the same two adjacent tasks converges the midpoint key toward one bound. A rebalancing step (spread all keys in a column evenly via batch write) is not yet implemented. The string-based approach degrades gracefully by extending key length rather than losing precision, but rebalancing should be added eventually.

**Snapshot fires on own writes.** `renderTaskAdded` deduplicates by checking if a card with the given `taskId` already exists in the DOM before inserting. `renderTaskModified` skips text updates while the card is in inline-edit mode (`dataset.inlineEditing === 'true'`).

**Placeholder rotation.** Each task input has a `setInterval` for rotating placeholder text. The interval is cleared when columns are removed (`cleanupColumns`). Failing to clear these causes memory leaks.

## Known Gaps

The following are things not evident from reading the code that would be valuable context for future sessions:

- **Vercel deployment config** — how deploys are triggered, environment variables, preview vs production
- **Firestore quotas and billing** — current usage levels, read/write cost awareness
- **User base** — how many active users, whether multiple people share accounts, geographic distribution
- **Browser/device support** — minimum browser versions, mobile support status (sidebar is hidden on narrow screens but touch drag-and-drop is not implemented)
- **Error monitoring** — whether there is any crash reporting, Firestore error alerting, or analytics beyond basic GA
- **Video assets** — exact purpose and source of the three MP4 files, whether they should be optimized or lazy-loaded
- **Background images** — `SisyphusImage9.png` referenced in CSS, whether other numbered images exist or are used
- **Planned features** — roadmap items, feature requests from users
- **Rollback strategy** — how to revert the migration if issues surface (the old `columnsByBoard` task arrays still exist in Firestore but are no longer written to)
- **Shared/collaborative boards** — whether multi-user access to the same board is planned (current security rules scope everything to a single uid)
- **Offline support** — whether Firestore offline persistence is intentionally enabled or disabled, expected behavior when connectivity drops
- **Task limits** — maximum tasks per column or board before performance degrades, whether any server-side limits should be enforced in security rules
