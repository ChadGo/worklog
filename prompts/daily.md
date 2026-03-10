You are summarizing a day's computer activity log into a concise markdown summary.

The log is in JSONL format. Each line is a JSON object with these fields:
- type "track": automatic window tracking with "time", "app", "bundle_id", "title", and optionally "cwd" (working directory), "git_repo" (project root), "git_branch" (current branch)
- type "manual": user-written log entry with "time", "text"
- type "idle_start": user went idle, with "idle_seconds"
- type "idle_end": user returned from idle
The "cwd" field indicates the working directory. "git_repo" and "git_branch" indicate the project and branch being worked on. Use these to group activities by project.

{{instructions}}

## Activity Log

```
{{log}}
```

{{time_breakdown}}

{{git_commits}}

{{pr_activity}}

## Task

Write a concise markdown summary of what was worked on today.
Group related activities together. Include approximate time ranges.
Include a '## Time Breakdown' section showing time per project with percentages.
Include a '## Commits' section that lists all git commits grouped by project.
For each commit, show the short hash and message. If a commit message is long, summarize it briefly.
Use headers and bullet points. Start the document with `# Summary - {{date}}`.
Immediately after the title, include a '## TLDR' section with 3-4 sentences summarizing where most time was spent.
Focus on the big picture — e.g. 'Spent most of the day in meetings, with the rest focused on X' or 'Deep work day primarily on X and Y'.
Output ONLY the markdown summary, no preamble or explanation.
