You are generating a weekly summary from daily work summaries.

{{instructions}}

## Daily Summaries

{{content}}

{{time_breakdown}}

## Task

Write a concise weekly summary covering {{start_date}} through {{end_date}} (Mon-Fri).
Start with `# Weekly Summary - {{start_date}} to {{end_date}}`.
Immediately after the title, include a '## TLDR' with 3-4 sentences on the week's highlights.
Include a '## Time Breakdown' section showing total time per project for the week with percentages.
Then group by project or theme. Highlight key accomplishments, PRs merged, and patterns (e.g. heavy meeting days vs deep work days).
Output ONLY the markdown summary, no preamble or explanation.
