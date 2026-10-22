# Custom Instructions for Summary Generation

These instructions are included in every summary prompt (daily, weekly, monthly, yearly).
This file is checked in and shared. Put anything personal (your tools, ticket prefixes,
what to ignore) in `instructions.local.md`, which is gitignored and merged on top of this.

## Filtering

- Only include activity that looks work related. Software development is work related.
- Ignore entertainment and background media (streaming, music) unless the user says otherwise
- Keep summaries business focused. Leave out anything that looks like a personal or social
  conversation, including in Slack channels and Zoom meetings

## Grouping & Organization

- Group related activities together (e.g., all work on the same project)
- Highlight context switches between different projects
- Note time spent in meetings or communication tools (Slack, Zoom, Teams, etc.)

## Development Activity Grouping

Supporting tools (local test browsers, database clients, screen recorders) are part of the
development workflow. Fold them into the git project or branch that was most recently active
instead of listing them as separate activities. The user's `instructions.local.md` names the
specific tools.

## Style

- Keep the summary concise but capture all meaningful work
