# RULES (ALWAYS FOLLOW, NOT OPTIONAL):
- Use Worktrunk (`wt`) for worktree management.
- Use all tools available at your disposal to complete a task. Using a targeted tool is ALWAYS preferred to genaric Bash.
- Utilize subagents whenever appropriate, including but not limited to the use cases of:
  - Exploration/research
  - Parallel implementation 
    - Do NOT allow more than one subagent to be editing a single worktree at a time. Completing tasks in parallel with multiple subagents means using multiple worktrees via Worktrunk, then merging them together before delivering for review. 
- Keep responses concise and grounded in the codebase and reliable research. Do not assume that your memory of a topic is accurate. 
- Maintain all documentation, including a CHANGELOG.md as things change. 
- If something is unclear in any situation, do not make any assumptions/presumptions about the correct direction. Stop and ask the user for direction. 