# Repository Activity Dashboard Setup

This bundle fixes the missing `data/repo-data.json` file shown in the browser console and wires the dashboard to update from GitHub every 6 hours.

## Files to add to the GitHub Pages repository

- `repository_dashboard.html`
- `scripts/fetch-repo-data.js`
- `.github/workflows/update-repo-dashboard.yml`
- `data/repo-data.json`

The dashboard fetches:

```text
./data/repo-data.json
```

So the JSON file must be committed at:

```text
data/repo-data.json
```

relative to `repository_dashboard.html`.

## Required GitHub secret

Create a repository secret named:

```text
REPO_DASHBOARD_PAT
```

Use a fine-grained personal access token that can read repositories in the `GoldrattConsultingIndia` organization.

For public repositories only, grant read access to public repository metadata. For private repositories, grant access to the target private repositories as well. The workflow itself uses `GITHUB_TOKEN` permissions to commit the generated `data/repo-data.json` back into the Pages repository.

## How it runs

```text
GitHub Action, every 6 hours
        ↓
GitHub API using REPO_DASHBOARD_PAT
        ↓
data/repo-data.json
        ↓
GitHub Pages dashboard
```

You can also run it manually from the Actions tab with **Run workflow**.

After the first successful run, refresh:

```text
https://goldrattconsultingindia.github.io/Utilities/repository_dashboard.html
```

The browser console should no longer show the `404` for `data/repo-data.json`.
