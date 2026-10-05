# Personal Mac Workspace

Status: draft derived from the requirement note. Release boundaries below are proposals, not confirmed scope. A working implementation covering most of phases 1–5 exists; see README.md for what is built.

## Product purpose

A local-first Mac application that remembers the context around the user's work: where files live, which services are involved, what information matters, and what needs attention next.

The primary success scenario is reopening Ayuvam, Presently, or a client project after 20 days and understanding it without reconstructing its context from memory.

## Principles

- Existing folders remain in place. Connecting a folder stores a reference and does not copy or import its contents into an app-owned filesystem.
- Project metadata and authored content are local by default. External websites and services still communicate with their providers when opened.
- Secrets require dedicated secure storage; they must not be ordinary note fields.
- Projects show only the sections the user enables, with useful defaults and progressive disclosure.
- Pending work remains visible even when a notification is missed.
- Idle operation should avoid continuous polling, recursive scanning, and hidden active web pages.
- Simple operations should take few steps. Features should support recovering project context.

## Organization and records

| Record | Purpose |
| --- | --- |
| Project | The common workspace for a brand, product, job, experiment, or client engagement. Contains a description, status, sections, and related records. |
| Client | A profile grouping multiple projects, with contact details and shared context. Projects can also exist without a client. |
| Section | An enabled area of a project, with a customizable name and position. Initial flexibility means configurable sections, not a general database schema builder. |
| Resource | A named link, reference, document reference, or other reusable entry with a type, description, and tags. |
| Folder connection | A reference to an existing local directory, its purpose, and current access status. A project can have several. |
| Repository | A remote URL, optional connected local checkout, and notes. |
| Service | Provider, purpose, dashboard URL, account identifier, environment, notes, and optional references to securely stored credentials. |
| Note | A titled Markdown document belonging to a project. |
| Prompt | A named reusable prompt, optional usage notes, and related resources. |
| Conversation link | A saved AI conversation URL, title, and short context summary. Saving a link does not import its conversation history. |
| Task | Work belonging to a project, with status, optional due date, reminder schedule, and related records. |
| Social account | Platform, profile URL, optional management URL, account label, and related posting work. |
| Content item | A planned post with target platforms, source asset references, caption or notes, and per-platform completion state. |
| Diagram | Nodes and connections, optionally referencing existing project records. |
| Image recipe | Reusable crop, resize, effect, and text settings used to generate project-associated exports. |

Records should use stable identifiers so renaming a service or resource does not break its tasks or diagram connections. Shared resources should be referenceable from multiple projects without duplicating credentials or files.

## Navigation and screens

### Home

Show overdue work, today's work, upcoming reminders, and project-level attention summaries. Separate overdue work from future scheduled items. Offer quick task capture, project search, and direct navigation to the relevant project or record.

### Project overview

Show a short description, current status, a pinned context note, key entry points, and pending work. Key entry points can include the working folder, repository, website, hosting dashboard, and relevant accounts. Optional sections live in project navigation instead of crowding the overview.

Suggested starting sections: Overview, Tasks, Resources, Files, Services, Notes, and Prompts. Social, Diagrams, and Image Tools can be enabled when useful. Chat links may appear as resources with their own filter.

### Client overview

Show client context, linked projects, and pending work across those projects. Opening a project uses the same project interface as personal and commercial work.

### Search

Search project names, resource titles, service names, notes, prompts, and tasks. Exclude secret values. Searching the contents of all connected source folders is outside the proposed first release.

## Functional requirements

### Connected folders and files

- Select an existing folder and assign its purpose, such as source code, generated assets, or exports.
- Browse its contents on demand; open files, open the folder, and reveal items in Finder.
- Load large directories incrementally and generate previews only when useful.
- Handle denied access, moved folders, disconnected volumes, and missing files with a clear status and reconnect action.
- Removing a connection removes the app's reference only. It must not delete the source folder or its files.
- File editing, moving, renaming, and deletion are outside the proposed initial browser scope.

### Resources, repositories, and services

- Add, edit, pin, search, and remove references.
- Record hosting, databases, domains, payment gateways, email, analytics, social platforms, SEO tools, and custom service types.
- Store an account label and environment so similar dashboards remain distinguishable.
- Open saved destinations directly. A stored repository link does not imply automated Git operations or GitHub synchronization.
- Keep chat summaries alongside conversation links so some context remains if the remote conversation becomes unavailable.

### Secrets and private data

- Store passwords, API keys, and tokens through a dedicated secure credential facility. The exact implementation requires a technical design review before real secrets are entered.
- Store only credential references and non-secret labels in ordinary project records.
- Mask secrets by default and require deliberate actions to reveal or copy them.
- Exclude secret values from search, logs, analytics, notifications, previews, and ordinary exports.
- Define unlock, clipboard handling, deletion, backup, and recovery behavior before shipping credential storage.
- Do not upload local files, source code, notes, or credentials as part of background operation.
- Distinguish credential protection from protection of ordinary notes, app backups, and the underlying Mac account.

### Notes, prompts, and conversations

- Provide a simple Markdown editor with autosave for notes.
- Provide named prompts that can be copied and reused.
- Allow links between notes, prompts, conversations, services, and tasks.
- Store conversation links and summaries; automatic chat scraping and history ingestion are outside the proposed scope.

### Tasks and reminders

- Create, edit, complete, reopen, and defer tasks.
- Distinguish a due date from a notification time. A task can have either or both.
- Support one-off reminders and recurring schedules, including daily, every N days, weekly on selected weekdays, and multiple times per day.
- Distinguish calendar recurrence from a follow-up N days after completion.
- Keep occurrence history so completing today's recurring work does not complete future work.
- Provide snooze for an occurrence without silently changing its recurrence rule.
- Show unfinished occurrences after sleep, restart, notification dismissal, or notification permission denial.
- Specify timezone, daylight-saving, and missed-occurrence behavior. Proposed default: schedules follow the Mac's local timezone; missed work is summarized without a notification flood.
- Use system notification scheduling where supported, reconcile on launch or wake, and verify platform limits before choosing the scheduling design.
- Closing the main window should allow the configured reminder behavior to continue. Document and test behavior when the application is fully quit.

### Embedded web access and social media

- Allow a resource to open in an embedded web view or the default browser.
- Show the destination and provide basic back, forward, reload, and external-open controls.
- Open web views on demand and release inactive views to constrain resource use.
- Provide an external-browser fallback for unsupported authentication, downloads, and incompatible sites.
- Treat browser sessions separately from stored project credentials; do not automatically inject secrets into pages.
- Show social accounts alongside overdue, today, and upcoming posting work.
- Track posting completion per destination. Finishing Instagram work must not mark Facebook work complete.
- The proposed initial social workflow is manual posting and tracking. Automated publishing is a separate integration decision.

### Simple image tools

- Open an image from a connected project folder.
- Crop, resize, reposition within a canvas, apply noise and Gaussian blur, and add text with font and color controls.
- Provide configurable ratio presets, including square, portrait, and story, with manual crop adjustments for each output.
- Save reusable recipes and preview their effects before export.
- Preserve source images by default. Make overwriting a deliberate action.
- Export to a selected project-associated directory and retain references to the outputs.
- Decide formats, color handling, image-size limits, and recipe persistence during this feature's technical design.

### Diagrams

- Add simple nodes and labeled connections.
- Reuse project resources and services as linked nodes, while allowing freeform nodes.
- Follow a linked node to its source record.
- Reflect renamed records and visibly flag removed references.
- Support manual layout and local saving; a large collaborative diagram editor is outside scope.

## Proposed release sequence

| Phase | Included capability | Exit condition |
| --- | --- | --- |
| 1: Context foundation | Projects and clients; configurable sections; folder connections; repository and resource links; service records; notes, prompts, and chat links; basic search; local persistence and backup. | Ayuvam and Presently can be populated, closed, and reopened with their context and original folder references intact. |
| 2: Daily work | Tasks; recurrence; notifications; Home attention view; social accounts and manual per-platform posting work. | Due work remains correct across missed notifications, sleep, relaunch, and recurring-task completion. |
| 3: Secure access and previews | Reviewed secure credential storage; embedded web access; richer file and image previews. | Credential handling passes explicit checks and web access has reliable external-browser fallbacks. |
| 4: Asset workflows | Image tools, ratio variants, reusable recipes, and project-associated exports. | A source image can produce manually adjusted variants without changing the original. |
| 5: Visual context | Diagrams linked to project records and workflow refinement. | A project's service relationships can be drawn and followed back to their records. |

Security constraints apply from phase 1. Until dedicated credential storage ships, service records must not invite users to paste secrets into notes. If storing credentials immediately is essential, move secure storage into phase 1 before using the app with real projects.

## Data ownership and recovery

- Separate app-owned metadata and authored text from externally referenced files.
- Provide a versioned backup/export and restore process for app-owned information.
- Explain that backing up metadata does not back up connected folders or guarantee restoration of credentials.
- On restore, detect broken folder access and offer reconnection.
- Keep database migrations recoverable and validate references after migration.
- Project deletion must explain which app-owned records are removed; external files remain untouched.

## Verification scenarios

1. Connect an existing folder, restart the app, and browse it without creating a second copy.
2. Move or disconnect that folder and recover its connection without losing project context.
3. Reopen a populated project after an absence and locate its files, services, conversations, and pending work from its overview.
4. Deny notifications and confirm overdue work still appears in Home and the project.
5. Complete one recurring occurrence and verify future occurrences remain scheduled.
6. Miss several recurring occurrences and verify the catch-up behavior is understandable and bounded.
7. Restore a metadata backup and reconnect unavailable folders without modifying their contents.
8. Confirm secrets do not appear in ordinary exports, search results, notification bodies, or logs.
9. Export image variants to a connected folder and verify the original remains unchanged.
10. Rename a service and confirm linked tasks and diagram nodes still resolve correctly.

Performance verification should cover idle resource use, launch time, large-folder browsing, preview generation, and active versus inactive web views. Numerical budgets remain to be set against the target Mac and expected data volume.

## Decisions still needed

- Immediate deliverable: product specification, visual prototype, or working native app foundation.
- Minimum supported macOS version and whether distribution is personal-only initially.
- Whether secure credentials must be in the first usable release.
- Expected number of projects and size of connected folders.
- Whether any future sync is desired; this draft assumes a single-user, single-Mac first release.

Implementation language, persistence framework, credential mechanism, and notification architecture remain provisional until the platform requirements are checked.
