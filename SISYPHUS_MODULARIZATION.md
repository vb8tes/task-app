# Sisyphus — Modularization Plan

## Starting Point

Sisyphus is currently a single `index.html` file (~3200 lines) containing all HTML, CSS, and JavaScript. There is no build step — the file is deployed directly to Vercel. The goal is to split this into a modular project structure using Vite as a bundler, without changing any functionality.

## Why Vite

Vite requires near-zero configuration, supports vanilla JS out of the box (no framework needed), provides hot module reload during development (save a file, browser updates instantly), and produces an optimized production bundle automatically. It is the lightest-weight way to get a real build pipeline.

## Phase 1 — Scaffold the Vite project (do first)

This phase changes the project structure but should produce identical behavior in the browser.

1. **Initialize Vite.** Run `npm create vite@latest` in the repo root, selecting vanilla JS. This creates a `package.json`, `vite.config.js`, and a minimal project scaffold.

2. **Extract CSS.** Move all the CSS (currently inside `<style>` tags in `index.html`, ~940 lines) into a standalone `style.css` file. Import it from the main JS entry point with `import './style.css'`.

3. **Extract the script block.** Move the entire `<script type="module">` block (~2270 lines) into `main.js`. Update `index.html` to reference it with `<script type="module" src="/main.js"></script>`. At this point the app should work identically through Vite's dev server (`npm run dev`).

4. **Update Vercel config.** Change the Vercel build command to `npm run build` and the output directory to `dist`. Vite's build step will produce the bundled files there.

5. **Test everything.** Auth flow, board CRUD, task CRUD, drag-and-drop, animations, real-time sync across tabs. Nothing should behave differently.

## Phase 2 — Split JS into modules

Now that the app runs through Vite with a single `main.js`, start breaking it into logical files. Each file exports functions and imports what it needs from other files.

Suggested module boundaries (based on the existing code structure):

- `firebase.js` — Firebase imports, config, app/auth/db/provider setup. Exports `auth`, `db`, `provider`.
- `state.js` — Shared state variables (`currentUser`, `activeBoardId`, `boardList`, `boardStoreCache`, etc.). Exports and manages all mutable state.
- `modal.js` — The promise-based custom modal system. Exports `showModal`, `showConfirm`, `showPrompt`.
- `tooltip.js` — Tooltip system. Exports `initTooltips` or self-initializes on import.
- `utils.js` — `createEntityId`, `isDesktopBrowser`, `buildVersionStamp`, version fetching. Exports each utility.
- `ordering.js` — Fractional ordering logic (`orderKeyBetween`, `generateOrderKeyBeforeAll`, `generateOrderKeyAfterAll`). Exports each function.
- `animation.js` — Video playback system for task completion/deletion/undo. Exports `playAnimation` or similar.
- `settings.js` — Animation toggle, version display. Exports `initSettings`.
- `sidebar.js` — Sidebar expand/collapse, board list rendering, board drag-and-drop reordering. Exports `renderTaskListNav`, `initSidebar`.
- `firestore.js` — Board store ref, localStorage caching layer, save/load/persist functions. Exports `saveBoard`, `commitSaveNow`, `persistBoardColumns`, `persistBoardsIndex`, etc.
- `boards.js` — Board management (create, rename, reorder, delete). Exports each function.
- `migration.js` — `migrateUserTasksIfNeeded`. Exports the migration function.
- `tasks.js` — Surgical DOM updaters (`renderTaskAdded`, `renderTaskModified`, `renderTaskRemoved`), task snapshot listener. Exports relevant functions.
- `columns.js` — Column creation, `createColumnElement`, column-related actions. Exports relevant functions.
- `cards.js` — `createTaskCard`, inline edit logic. Exports relevant functions.
- `actions.js` — `addTask`, `toggleDone`, `deleteTask`, `deleteColumn`, `addColumn`. Exports each action.
- `auth.js` — Sign-in, sign-out, `onAuthStateChanged` handler, `beforeunload`. Exports `initAuth`.
- `main.js` — Entry point. Imports `initAuth`, `initSidebar`, `initSettings`, `initTooltips` and kicks everything off.

**How to approach this:** Move one module at a time, starting from the leaves (files with no dependencies on other app code, like `utils.js` and `ordering.js`). After extracting each module, test the app to make sure nothing broke. Work inward toward `main.js`.

**Circular dependency warning:** `state.js` will be imported by almost everything. That's fine — it's a common pattern. But avoid having `state.js` import from other app modules, or you'll create circular dependencies. Keep it as a pure data store.

## Phase 3 — Add a linter (do when modules are stable)

Install ESLint (`npm init @eslint/config`). Start with a minimal config — the default recommended rules are a good baseline. Run it against the codebase and fix any warnings. Add it as a pre-commit hook or CI check so issues are caught before deploy.

This will surface latent bugs (unused variables, unreachable code, implicit globals) that are easy to miss in a large codebase.

## Phase 4 — Add TypeScript (optional, do later)

Once the modular structure feels comfortable:

1. Rename files from `.js` to `.ts` one at a time (Vite supports TypeScript natively, no extra config).
2. Start with the simplest modules (`utils.ts`, `ordering.ts`) and add type annotations.
3. Define interfaces for your core data shapes — `Board`, `Column`, `Task`, `BoardStore`.
4. Gradually type the rest of the codebase. TypeScript in strict mode will catch a large class of bugs at edit time.

This is optional but especially valuable if the project grows or if you plan to build an iOS app later — typed data models transfer cleanly to Swift or React Native with TypeScript.

## Phase 5 — Production optimizations (do when needed)

- **Code splitting.** Vite can split the bundle so the auth/login screen loads first and the rest loads after sign-in. Useful if the bundle gets large.
- **Asset optimization.** Move the MP4 video files and background images into the Vite asset pipeline so they get hashed filenames (for cache busting) and can be lazy-loaded.
- **Environment variables.** Move the Firebase config into `.env` files so development and production can use different Firebase projects if needed.

## Notes

- Each phase is independent and deployable. You don't need to complete all phases — stop wherever the complexity-to-benefit ratio stops making sense.
- The Firestore schema, security rules, and data model are completely unaffected by modularization. This is purely a code organization change.
- Existing user data and sessions will not be impacted at any phase.
- The `profile` field on board objects in Firestore is legacy data from the removed alias/role system. It can be ignored — no need to migrate or clean it up.
