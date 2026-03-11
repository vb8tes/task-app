# Sisyphus — Sync Refactor Briefing

## Context

**Sisyphus** is a Kanban-style task management web app built as a single `index.html` file (~2000 lines). It uses:

- **Firebase Auth** (Google sign-in) for identity
- **Firestore** for persistence and real-time sync
- **Vanilla JS** (ES modules, no framework)
- A Sisyphus mythology theme throughout: tasks are "boulders", columns are "Mountains", boards are "Worlds"

The app supports multiple boards ("Worlds") per user, each with multiple columns ("Mountains"), each column with active and completed task lists. Drag-and-drop works for tasks, columns, and boards. There are contextual video animations (completing a task, deleting a task, undoing completion).

The app is currently deployed and has real user data that must not be lost.

---

## The Problem: Tasks Don't Sync Across Browser Sessions

Two users (or the same user in two browsers) logged into the same account see different task states that don't reconcile. Changes made in one browser are either delayed, overwritten, or lost entirely when the other browser saves.

---

## Why the Current Architecture Fails

### The save model

Every user action (add task, toggle done, drag card, rename column) calls `saveBoard()`, which:

1. Calls `collectBoardColumns()` — reads the **entire board state from the DOM** as an array
2. Calls `persistBoardColumns()` — **overwrites the entire Firestore document** with that array

```js
// Current Firestore document shape (one doc for the whole user):
// users/{uid}/board/data
{
  boards: [ { id, name, profile } ],           // board index
  columnsByBoard: {
    "board-id-1": [
      {
        id: "col-id",
        name: "Mountain 1",
        tasks: ["Buy milk", "Call dentist"],    // plain text, no IDs
        completed: ["Fix bug"]
      }
    ]
  }
}
```

### The race condition

Two browsers editing simultaneously both overwrite the entire `columnsByBoard[boardId]` array. Last write wins, and the loser's changes are silently discarded.

**Concrete example:**
1. Browser A and B both show tasks `[1, 2, 3]`
2. Browser A adds task 4 → saves `[1, 2, 3, 4]`
3. Browser B's `onSnapshot` fires, re-renders to `[1, 2, 3, 4]` ✓
4. Browser B adds task 5 (from its DOM, now `[1, 2, 3, 4, 5]`) → saves `[1, 2, 3, 4, 5]`... but if step 3 hadn't completed yet, B saves `[1, 2, 3, 5]`
5. Browser A's `onSnapshot` fires → re-renders to `[1, 2, 3, 5]` — **task 4 is gone** ✗

### The guard that makes it worse

The `onSnapshot` listener has this guard:

```js
if (!savePromise) {
    // only apply remote update if not mid-save
    const remoteColumns = columnsByBoard[activeBoardId];
    if (JSON.stringify(localColumns) !== JSON.stringify(remoteColumns)) {
        cleanupColumns();
        renderColumnsForBoard(remoteColumns);  // full DOM wipe + rebuild
    }
}
```

If a snapshot arrives while Browser A is saving, A skips it entirely. When A's save finishes, no new snapshot fires — A is now permanently out of sync until one of them makes another change.

### Additional structural problems

- **Tasks have no stable identity.** They are stored and compared as plain text strings. Renaming a task creates a new task identity on the next save.
- **`collectBoardColumns()` reads from the DOM.** The DOM is the source of truth, not a JS data model. This makes it impossible to track individual changes.
- **Full re-render on sync.** `renderColumnsForBoard()` tears down and rebuilds the entire column DOM. Combined with frequent saves, this causes flicker and loses focus state.
- **`saveBoardTimer` not checked in snapshot guard.** After adding a debounce to `saveBoard()`, there's now a window where `savePromise` is null but `saveBoardTimer` is pending — the guard incorrectly allows remote updates to overwrite unsaved local changes during this window.

---

## The New Architecture

### Schema — Option B (recommended)

```
users/{uid}/board/data                          ← board index + column metadata only
users/{uid}/boards/{boardId}/tasks/{taskId}     ← one document per task
```

**Board index document** (`users/{uid}/board/data`) — unchanged from current, still stores the `boards` array (world list + column order/names). Written infrequently (board rename, column rename, column reorder).

**Task documents** (`users/{uid}/boards/{boardId}/tasks/{taskId}`):

```js
{
  id: "task-abc123",          // Firestore doc ID, stable forever
  text: "Call dentist",       // mutable, but ID never changes
  columnId: "col-xyz",        // which column this task belongs to
  done: false,                // completion state
  orderKey: "a0m",            // fractional/lexicographic sort key
  createdAt: Timestamp        // for tiebreaking and debugging
}
```

**Why Option B over Option A:**
- Queries naturally scope to `boardId` — no `where('boardId', '==', x)` filter needed
- Firestore security rules are trivial: `match /boards/{boardId}/tasks/{taskId}` maps directly to access control
- No risk of cross-board task contamination

---

## Specific Actions Required

### 1. Add stable task IDs to the DOM

Every task card element must carry its Firestore doc ID:

```js
// When creating a task card:
li.dataset.taskId = task.id;   // store on the element

// When reading task identity (replace textContent reads):
const taskId = li.dataset.taskId;
```

The existing `createEntityId('task')` helper can generate these, or use Firestore's `doc()` auto-ID.

### 2. Replace `collectBoardColumns()` with per-action writes

Remove the "read DOM → serialize → overwrite Firestore" pattern entirely.
Each user action becomes a discrete, targeted Firestore write:

```js
// Add task
async function addTask(col, text) {
    const taskId = createEntityId('task');
    const orderKey = generateOrderKeyAtEnd(col);
    await setDoc(taskDocRef(boardId, taskId), {
        id: taskId, text, columnId: col.dataset.id,
        done: false, orderKey, createdAt: serverTimestamp()
    });
    // DOM update happens via onSnapshot — do NOT update DOM here
}

// Toggle done
async function toggleDone(taskId, currentDone) {
    await updateDoc(taskDocRef(boardId, taskId), { done: !currentDone });
}

// Delete task
async function deleteTask(taskId) {
    await deleteDoc(taskDocRef(boardId, taskId));
}

// Move task (drag-and-drop)
async function moveTask(taskId, newColumnId, newOrderKey) {
    await updateDoc(taskDocRef(boardId, taskId), {
        columnId: newColumnId, orderKey: newOrderKey
    });
}

// Rename task (if added in future)
async function renameTask(taskId, newText) {
    await updateDoc(taskDocRef(boardId, taskId), { text: newText });
}
```

### 3. Implement fractional orderKey

Used for task ordering within a column. Allows a single-document update on move/reorder rather than rewriting every task's position.

**Algorithm:**
- New task at end: `maxExistingKey + 1` (or `"a0"` if empty)
- Insert between A and B: midpoint of their keys
- Use a lexicographic string approach (e.g. the `fractional-indexing` npm package) rather than raw floats to avoid floating-point precision exhaustion
- When gap between two adjacent keys drops below epsilon, rebalance: spread all keys in the column evenly and batch-write (rare operation)

```js
function orderKeyBetween(before, after) {
    // Use fractional-indexing library or implement midpoint string
    // Returns a key strictly between `before` and `after`
}
```

### 4. Replace the snapshot listener with `docChanges()`

Instead of re-rendering the whole board on any change, apply surgical DOM deltas:

```js
onSnapshot(
    query(tasksCollection(boardId), orderBy('orderKey')),
    snapshot => {
        snapshot.docChanges().forEach(change => {
            const task = { id: change.doc.id, ...change.doc.data() };
            if (change.type === 'added')    renderTaskAdded(task);
            if (change.type === 'modified') renderTaskModified(task);
            if (change.type === 'removed')  renderTaskRemoved(task.id);
        });
    }
);

function renderTaskAdded(task) {
    // Find the column, insert card at correct orderKey position
    // Only if no card with this taskId exists yet
}

function renderTaskModified(task) {
    // Find existing card by dataset.taskId
    // Update text, done state, move to new column if columnId changed
    // Re-sort within column if orderKey changed
}

function renderTaskRemoved(taskId) {
    // Find card by dataset.taskId and remove it
}
```

**Critical:** Do not update the DOM from action functions (add, toggle, delete, move). Let the snapshot listener be the single source of DOM truth. This means the UI feels slightly async but is always consistent.

### 5. Keep `saveBoard()` only for column/board metadata

The existing save mechanism can remain for non-task data: column names, column order, board names, board order. These change infrequently and don't have concurrent-edit conflicts in practice. The debounce and save queue already in place are fine for this.

```js
// saveBoard() now only persists column metadata, not tasks:
function collectBoardMetadata() {
    // Returns column order + names only, no task arrays
}
```

### 6. Rollout plan (dual-write, safe migration)

**Phase 1 — Dual-write:** Write tasks to both old array format AND new task subcollection simultaneously. Read still uses old format. This allows instant rollback.

**Phase 2 — Switch reads:** Change the snapshot listener to use `docChanges()` on the tasks subcollection. Remove old `renderColumnsForBoard()` full-render path for tasks.

**Phase 3 — One-time migration:** For each existing user, on first login after the switch, read their current `columnsByBoard` arrays and write each task as an individual document with a generated `orderKey`. Mark migration complete with a flag in the board store document. Migration must be **idempotent** — if it runs twice, no duplicates.

```js
async function migrateUserTasksIfNeeded(data) {
    if (data.tasksMigrated) return;  // already done
    for (const [boardId, columns] of Object.entries(data.columnsByBoard || {})) {
        let order = 0;
        for (const col of columns) {
            for (const text of col.tasks) {
                const id = createEntityId('task');
                await setDoc(taskDocRef(boardId, id), {
                    id, text, columnId: col.id, done: false,
                    orderKey: String(order++).padStart(8, '0'),
                    createdAt: serverTimestamp()
                });
            }
            for (const text of col.completed) {
                const id = createEntityId('task');
                await setDoc(taskDocRef(boardId, id), {
                    id, text, columnId: col.id, done: true,
                    orderKey: String(order++).padStart(8, '0'),
                    createdAt: serverTimestamp()
                });
            }
        }
    }
    await setDoc(boardStoreRef(), { tasksMigrated: true }, { merge: true });
}
```

**Phase 4 — Remove old writes:** Once migration is confirmed stable, remove the dual-write path and the old `columnsByBoard` task arrays from saves.

---

## Issues to Watch Out For

### orderKey precision exhaustion
If a user repeatedly drags the same task between two adjacent tasks, the midpoint key converges toward one of them. Use a string-based fractional index (not raw floats) and implement a rebalance step that triggers when two adjacent keys are within some minimum gap. The `fractional-indexing` library handles this correctly.

### Snapshot listener fires on own writes
Firestore's `onSnapshot` fires for changes made by the local client too. The `renderTaskAdded` function must check whether a card with that `taskId` already exists in the DOM before inserting, to avoid duplicates:
```js
function renderTaskAdded(task) {
    if (document.querySelector(`[data-task-id="${task.id}"]`)) return;
    // ... insert
}
```

### Migration idempotency
If a user's browser crashes mid-migration, the next login will re-run it. The migration must check for existing task docs before writing, or use Firestore's `create` semantics (fail if doc exists) rather than `setDoc` to prevent duplicates.

### Firestore security rules
The new subcollection path needs explicit rules. A minimal safe ruleset:
```
match /users/{uid}/boards/{boardId}/tasks/{taskId} {
    allow read, write: if request.auth.uid == uid;
}
```
Without this, all task reads/writes will be rejected.

### Optimistic UI vs. snapshot-only UI
Letting the snapshot listener be the sole DOM updater means there's a round-trip latency (write → Firestore → snapshot → DOM update) on every action. For low-latency feel, consider optimistic updates: update the DOM immediately on action, then let the snapshot confirm/correct. If the snapshot returns a different state (e.g. conflict resolved server-side), the correction will be applied. This is optional but improves perceived responsiveness.

### `collectBoardColumns()` must be fully removed or guarded
Any remaining call to the old `collectBoardColumns()` → `persistBoardColumns()` path for tasks will cause it to overwrite the new subcollection-sourced state with a stale DOM snapshot. Audit all `saveBoard()` calls and ensure they only write column metadata after Phase 4.

### The `if (!savePromise)` guard in the old snapshot listener
This guard should be removed entirely once the new listener is in place. It was a workaround for the overwrite problem — with per-action writes, there's no "full board save" in flight that could conflict with incoming snapshots.

---

## Files

- `index.html` — the entire app (~2000 lines, single file)
- `vercel.json` — deployment config, no changes needed
- `SisyphusImage1/2/3.png` — background images
- `*.mp4` — animation videos (boulder rolling back, getting crushed, reaching summit)

The Firebase project is `mysisyphus-xyz`. Firestore and Auth are already configured. The Firebase config object (API key etc.) is in the script and is safe to keep client-side — security is enforced via Firestore rules.
