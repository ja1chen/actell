---
name: skill-creator
description: Create or improve reusable user skills through conversation. Use when the user wants to teach the agent a workflow or save task guidance as a skill.
version: 1.0.2
---

# Skill Creator

Create useful task guidance from the user's goal and examples. Ask only for missing information that changes the result. Keep the skill within the user's intended scope; examples and past failures do not establish universal rules or authorize future external actions.

## Write a user skill

Local user skills live in `~/Documents/skills`, where `~` is the App's home directory. Each immediate subfolder is one skill, with `SKILL.md` at its root. Use existing `read`, `write`, `edit` and `bash` tools. Pass the home-relative path to file tools or the `bash` workdir parameter; plain relative paths start in the conversation working directory. There is no separate skill-saving tool or JSON archive to update.

Choose a short folder name using lowercase letters, digits and hyphens. Before changing an existing skill, inspect its current files and preserve unrelated guidance. Imported skills may have UUID folder names; keep those paths when editing. Write supporting references before the entrypoint when creating a package.

`SKILL.md` starts with simple metadata:

```markdown
---
name: skill-name
description: Explain what the skill does and when to use it.
version: 1.0.0
---

# Skill title

Task-specific guidance.
```

Use `name` and `description` as metadata keys in English; their values and the body may use the user's preferred language. The name must be 1–80 characters and the description 1–1000 characters. Metadata supports plain or quoted text and indented `|` / `>` multiline values. Do not generate nested YAML structures.

Include a top-level `version` field for newly created skills; start at `1.0.0` unless the user specifies a version. The App reads this field for display; it does not infer a version from the folder, file modification time or content hash. Skills without it remain loadable and show no version label. When changing an existing skill, preserve the current version unless the guidance changes; for a small correction increment its patch component, and follow any versioning convention already defined by the skill. Do not invent an existing version or rewrite unrelated metadata.

## Make the guidance reusable

Assume the agent already knows general problem solving. Include the useful decisions, project conventions, essential constraints and stopping conditions that would otherwise be missed. Keep names and descriptions precise enough for discovery. Keep essential guidance in the entrypoint; move substantial conditional detail into linked references that explain when to read them. Add files only when they have a concrete purpose.

The root `SKILL.md` must be UTF-8. `load_skill` takes only the skill name and returns the current entrypoint and its directory. Read references with `read`, resolving relative paths from that directory. For references listed in the returned document catalog, use relative paths ending in `.md`, `.markdown` or `.txt`, without hidden components or parent traversal. Skill folders can also contain scripts and assets. Use the normal file and command tools if those files are needed for the user's task. Skills cannot expand permissions. Do not save credentials, private runtime logs or one-off evidence in reusable guidance.

## Verify and report

Read back the entrypoint and any references using the existing tools. Check metadata, reference paths and whether the instructions preserve the user's scope. A successful write proves file creation; it does not prove the workflow was exercised. Explain what was created and any validation limits honestly.

The library rescans the directory when viewed, before a new run and on each `load_skill` call. New or edited skills can be loaded by name immediately within the current turn. Enablement is an App preference stored in UserDefaults, separate from skill documents. New skills default to enabled. Do not create `.disabled` files or change preferences as part of writing a skill; the user skill detail page controls enablement.
