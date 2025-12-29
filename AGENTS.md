Idenfity next work with `bd ready`. Follow the issue’s scope/guardrails and verify with the commands listed. Think hard.

Tell me what you are doing before adding notes/comments/updates to the issue about any decisions you make along with the resolution. If we come across behavior that is out of the scope of the current task, create/update an issue and stay focused on the current task. Add a note to the original issue (use `bd update --notes` with the resolution and/or any relevant details.

Use a foreground terminal instead of background terminal. Don't use `git add -A`; add specific files.

## bd workflow (how we run work)

### Pick work
- `bd ready` shows issues with no blockers.
- `bd blocked` shows what’s waiting on dependencies.
- Prefer starting with the highest priority issue in `bd ready`.

### Get full context for a task
- `bd show <issue-id>` is the source of truth for goal/scope/verification.
- `bd prime <issue-id>` outputs an AI-optimized context block you can paste into an agent prompt.
- `bd pin <issue-id>` pins important “global context” issues (e.g., lint policy, MethodChannel contract).
- `bd unpin <issue-id>` when no longer needed.

### Create and update issues
- Provide human user with a summary of why an issue needs to be created/updated
- Create: `bd create -t task -p P2 -d "<short title>"` (or use `bd create-form`).
- Update description/acceptance non-interactively:
	- `bd update <issue-id> --body-file - --acceptance "..."` (pipe markdown via stdin)
	- `bd update <issue-id> --description "..."` (short edits)
- Close when done: `bd close <issue-id>`.

### Dependencies (critical for agent throughput)
- Add dependency: `bd dep add <issue-id> <depends-on-id>`
	- Meaning: `<issue-id>` depends on `<depends-on-id>` (i.e., the dependency blocks the issue).
- Remove dependency: `bd dep rm <issue-id> <depends-on-id>`
- Visualize: `bd graph`.

### “Agent-runnable” issue template
When writing/updating an issue, include:
- Goal (1–2 sentences)
- Scope / non-goals
- Where (files/symbols)
- Repro steps or commands
- Verification / acceptance criteria
- Links to blocking policy/contract issues (and add `bd dep` links)

### Guardrails
- Don’t start blocked work: if it’s not in `bd ready`, resolve blockers first.
- If a task requires a policy/contract decision, create a separate issue for the decision and block dependent work on it.

### Useful shortcuts
- Search: `bd search "<text>"`
- List all: `bd list`

## development workflow

### Build:
- adb install -r build/app/outputs/flutter-apk/app-debug.apk

### Run:
- adb logcat -c && adb shell am start -n com.nordicmesh.nordic_mesh_manager/.MainActivity

### On device test:
- prompt user to run relevant steps

### Analyze:
- Examine the 'adb logcat' output for relevant details after the verification stage.


## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
