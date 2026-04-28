---
name: hello
description: Skill nested inside a plugin tree (smoke fixture). Verifies that reflect_dir_of_dirs treats the entire plugin subtree as one indivisible reflection unit.
---

# hello (nested inside sample-plugin)

This file's existence inside `~/.claude/plugins/sample-plugin/skills/hello/SKILL.md`
proves the helper recursively copied the deep tree, not just the top-level file.
