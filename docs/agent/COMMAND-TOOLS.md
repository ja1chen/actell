# Command tools

## Scope

Actell exposes `bash`, `read`, `edit`, and `write` to live model runs without replacing AgentKit, ProviderKit, device control, or the run lifecycle. Each conversation owns a persistent scratch directory at `Documents/workspaces/YYYY-MM-DD_<conversation UUID>/`, alongside the separate `Documents/sessions/` history tree. The directory name reuses the conversation's existing session directory name, so continuing a conversation or changing time zones does not rename its workspace. No workspace tool imports user attachments, reads skill packages, opens external document-picker grants, or accesses another conversation by default. Deleting a conversation does not currently garbage-collect its workspace; retention cleanup needs a separate product decision.

On first access, a workspace from `Library/Application Support/AgentWorkspaces/<conversation UUID>/` is moved to the corresponding dated directory. If both locations already exist, access fails and both are preserved without merging or overwriting. In-memory conversations use isolated temporary storage.

`bash` is a compatibility **tool name**, not GNU Bash. Ordinary iOS apps cannot spawn a system Bash process. This implementation uses precompiled ios_system commands in the App process. Command text is passed directly to the runtime without a host command-name or option allowlist. Missing programs return the runtime's `command not found` diagnostic and exit code 127; invalid options and unsupported syntax are likewise reported by the runtime.

The bundled core, files, text and shell modules supply the command runtime. Tool descriptions do not enumerate available commands or options; the model uses returned output, exit codes and errors to choose its next action. Pipes, redirects, quoting, expansion and shell compatibility follow ios_system's behavior; arbitrary GNU Bash syntax is not promised. Additional interpreters or network/archive modules require separate dependencies.

Each invocation starts in the selected workspace directory. Working-directory changes, aliases and environment changes are not a persistent terminal session; use `workdir` on later invocations. The bridge restores the App's process working directory and resets its library-local environment after execution. The native mini-root limits directory switching and tilde expansion, but does not restrict all filesystem calls. Native commands run with the App's sandbox permissions and can use absolute paths or links; the starting workspace is not a per-conversation security sandbox. Model instructions require staying within the user's authorized task and avoiding credentials, app configuration and unrelated conversations. The separate `read`/`edit`/`write` tools retain their path and link validation.

## Reference contract and intentional differences

Reference: [DeepSeek Harness 0.2.2-rc.1 tool trace](https://phistory.cc/?view=trace&agent=dsh&version=0.2.2-rc.1), default variant. Only the public tool schema/semantics were used as a design reference; no system prompt was copied.

| Tool | Required | Optional |
| --- | --- | --- |
| bash | description, command | workdir, timeoutMs |
| read | file_path | description, offset, limit |
| edit | file_path, old_string, new_string | description, replace_all |
| write | file_path, content | description |

`read` uses one-based line offsets and numbered UTF-8 text, with bounded output. `edit` performs exact literal matching: a nonempty old string and exactly one match are required unless `replace_all` is true. Missing or ambiguous matches leave the file unchanged. `write` creates or atomically replaces a text file; limits prevent unbounded file/workspace growth. Results are JSON text, including relevant truncation/output metadata. Read pages never split a logical line; an individual line exceeding the output budget fails explicitly rather than silently skipping its tail. Unknown fields are ignored. Recognized fields retain their type, range, and path validation. File operations accept an optional public `description` for the tool card title.

Original DSH `sandbox_permissions`, `danger-full-access`, and `justification` escalation are not implemented. Original timeout-to-background-job behavior is also not implemented. There is no background job identifier, job_output/job_kill surface, or promise of continued execution after iOS suspends the app.

## Architecture and authorization

- `ExecutionTool` adapts AgentKit descriptors and invokes host lifecycle checks.
- `FileWorkspace` owns bounded filesystem operations and atomic replacement. Paths are restricted to the selected workspace; links and nonregular file types are rejected.
- `CommandKit` checks only the command transport envelope (nonempty text, no NUL bytes, bounded UTF-8 length) and supplies a serialized ios_system bridge with bounded output capture. The bridge must be the sole owner of ios_system in this App; its lock cannot protect unrelated direct callers. A process-wide workspace lane also serializes reads and writes with native commands, including time spent awaiting approval. This can delay tools in another conversation. Workspaces must have no external concurrent writers.
- `AgentViewModel` registers the four tools for live runs only. The scripted device demo remains unchanged.
- `bash`, `edit` and `write` use the existing one-use approval records, with per-action confirmation even when device control has task-level authorization. Arbitrary commands are treated as potentially mutating rather than falsely labeled read-only.
- The run lifecycle persists prepare/approval/dispatch/acknowledgment for commands and file mutations. AgentKit claims every tool call durably and recovery does not replay interrupted effects. A cancellation after a successful atomic file commit does not erase that completed result. An interrupted native command may have partial effects and is recorded as unknown rather than retried.
- Invocation cancellation/fence checks occur before effects, including after queued shell work is admitted. In-process C cancellation is cooperative: a timeout requests interruption and waits for the command to exit before releasing shared state. This is not a hard wall-clock timeout. A noncooperative native command can delay cancellation; validate this on-device before production use.

Workspace text returned by tools is sent to the configured model provider as conversation context. Do not store credentials in workspaces or place them in shell arguments. Upstream native diagnostic logging may include command strings. File-size, entry and workspace quotas belong to `FileWorkspace` operations; native commands are not covered by those quotas. Output capture remains bounded and drained while native commands run.

## Dependency and build

Use the pinned ios_system core, files, text and shell modules rather than upstream's all-inclusive package product. The local package records upstream release URLs and checksums. `THIRD_PARTY` retains the pinned upstream command dictionaries and license. After resolving artifacts, regenerate the App registry with `python3 ios-app/scripts/generate_command_dictionary.py`. It registers upstream aliases and exported command entry points present in both device and simulator binaries, correcting framework ownership from actual symbols. This is the runtime's symbol registry, not a host execution allowlist or a model-facing command inventory. Adding modules requires updating the generator's module inputs and preserving their notices.

Regenerate the checked-in project with:

```sh
python3 ios-app/scripts/generate_xcode_project.py
```

Then follow the existing App build/test instructions. The ios_system binary slicing, dynamic command lookup, simulator architecture and runtime symbol loading must be validated in Xcode. A valid package manifest or generated project does not establish that native linking succeeds.

## Acceptance matrix

1. Resolve the pinned artifacts and verify checksums; build unsigned iPhoneOS and supported simulator targets.
2. Run file tests: Unicode, empty/trailing-newline text, pagination, exact/ambiguous edits, overwrite atomicity, quotas, traversal, symlink/hardlink and directory rejection.
3. Run envelope and native tests: working directories, file commands, full native options, pipelines, redirects, output truncation and command-not-found exit 127. Check exit 1 for no grep match separately from execution errors.
4. Deny a command or file mutation: no dispatch. Approve once: exactly one invocation. Expire approval: no effect.
5. Stop while awaiting approval, queued, reading, and executing native code; check output is drained and no native runtime overlap occurs.
6. Background, lock, foreground and resume; verify lifecycle behavior without promising unsupported continuous background execution.
7. Relaunch after an interrupted write and after a completed write: do not replay; verify file contents and durable tool outcome.
8. Two conversations: no starting-directory, alias or environment leakage. Check the file tools' traversal/link rejection separately; native commands are not a per-conversation filesystem sandbox.

This is a noninteractive command runtime, not a complete terminal product. Terminal UI, external folder grants, background-job management, full GNU Bash and unbundled interpreters/network modules are outside its scope.
