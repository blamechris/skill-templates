paths: .github/workflows/*.yml, deploy.sh

- In GitHub Actions self-hosted runners, `gh` CLI has no auth session. Always `export GH_TOKEN` from the deploy PAT before `gh pr`/`gh issue` calls.
- Workflow `if:` conditions compare step outputs as strings. Use `!= '0'` not `> 0` for numeric-like comparisons.
