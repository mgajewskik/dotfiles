---
description: Delegate a task asynchronously with explicit criteria and context
argument-hint: "<task>"
---
Start the default subagent with action "start" for this task: $@
Supply task, criteria (checkable success conditions), antiCriteria (outcomes to avoid), and context containing the relevant files, facts, constraints, decisions and prior findings. The child does not share this conversation. Resolve essential ambiguities before dispatch.
Return its handle immediately and continue independent work. Use send for new context and read/status when the result is needed; avoid unnecessary polling.
