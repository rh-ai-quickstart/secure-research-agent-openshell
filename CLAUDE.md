# Secure Research Agent — Agent Guidelines

Read and follow AGENTS.md in full. It contains skill discovery, request routing, and project context.

On session start, ensure skills are synced:

```bash
ls .claude/skills/deploy-aiq-openshell/SKILL.md 2>/dev/null || bash scripts/sync-skills.sh
```

Then read the skill file at `.claude/skills/<skill-name>/SKILL.md` when the user requests a deployment action.
