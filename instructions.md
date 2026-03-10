# Custom Instructions for Summary Generation

These instructions are included in every summary prompt (daily, weekly, monthly, yearly).
Edit this file to control how your summaries are generated.

## Filtering

- Ignore Netflix, YouTube, and Spotify activity — this is background music/entertainment

## Grouping & Organization

- Group related activities together (e.g., all work on the same project)
- Highlight context switches between different projects
- Note time spent in meetings or communication tools (Slack, Zoom, Teams, etc.)

## Development Activity Grouping

These tools are part of the development workflow and should be grouped with the most recently active git project/branch:

- **Browser on localtest.me** (e.g. app.localtest.me:3000) — this is testing the app locally, associate it with the most recent git branch
- **DBeaver** — database access, associate with the most recent git project being worked on
- **Loom** — recording PR walkthroughs, associate with the most recent git branch/PR

When these tools appear in the log, don't list them as separate activities. Instead, fold them into the project context they belong to (e.g. "Worked on GS1-7168 feature branch — coding, local testing, database queries, and recorded PR walkthrough").

## Style

- Keep the summary concise but capture all meaningful work
