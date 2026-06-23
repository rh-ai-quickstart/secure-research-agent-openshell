---
description: Project guidelines and skill discovery for the secure research agent quickstart
globs: "**/*"
---

# Secure Research Agent — Cursor Rules

Read and follow AGENTS.md in the project root. It contains skill discovery, request routing, and project context.

On session start, ensure skills are synced:

```bash
ls .cursor/skills/deploy-aiq-openshell/SKILL.md 2>/dev/null || bash scripts/sync-skills.sh
```

## Skills

Skills are located at `.cursor/skills/<skill-name>/SKILL.md` (symlinked from `skills/`).

| Skill | Use when |
|-------|----------|
| deploy-aiq-openshell | User asks to deploy, redeploy, or troubleshoot the full stack |
| deploy-openshell-openshift | User asks to deploy only the OpenShell gateway |

Read the SKILL.md file before executing any deployment action.
