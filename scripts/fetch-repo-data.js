const fs = require('fs/promises');
const path = require('path');

const org = process.env.ORG_NAME || 'GoldrattConsultingIndia';
const token = process.env.GH_PAT || process.env.GITHUB_TOKEN;
const outputPath = process.env.OUTPUT_PATH || 'data/repo-data.json';
const includeArchived = process.env.INCLUDE_ARCHIVED === 'true';

if (!token) {
  throw new Error('Missing GH_PAT or GITHUB_TOKEN.');
}

const headers = {
  Accept: 'application/vnd.github+json',
  Authorization: `Bearer ${token}`,
  'X-GitHub-Api-Version': '2022-11-28',
  'User-Agent': 'repository-activity-dashboard',
};

async function githubJson(url) {
  const response = await fetch(url, { headers });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`${response.status} ${response.statusText} from ${url}\n${body}`);
  }

  return response.json();
}

async function fetchAllRepos() {
  const repos = [];
  let page = 1;

  while (true) {
    const url = new URL(`https://api.github.com/orgs/${org}/repos`);
    url.searchParams.set('type', 'all');
    url.searchParams.set('sort', 'pushed');
    url.searchParams.set('direction', 'desc');
    url.searchParams.set('per_page', '100');
    url.searchParams.set('page', String(page));

    const batch = await githubJson(url);
    repos.push(...batch);

    if (batch.length < 100) break;
    page += 1;
  }

  return repos.filter((repo) => includeArchived || !repo.archived);
}

async function fetchLatestCommit(repo) {
  if (!repo.default_branch) return null;

  const commitsUrl = new URL(`https://api.github.com/repos/${org}/${repo.name}/commits`);
  commitsUrl.searchParams.set('sha', repo.default_branch);
  commitsUrl.searchParams.set('per_page', '1');

  try {
    const commits = await githubJson(commitsUrl);
    return commits[0] || null;
  } catch (error) {
    console.warn(`Could not read latest commit for ${repo.name}: ${error.message}`);
    return null;
  }
}

function pickAuthor(repo, commit) {
  return (
    commit?.author?.login ||
    commit?.commit?.author?.name ||
    repo.owner?.login ||
    repo.owner?.name ||
    'Unknown'
  );
}

async function main() {
  const repos = await fetchAllRepos();
  const enriched = [];

  for (const repo of repos) {
    const commit = await fetchLatestCommit(repo);

    enriched.push({
      name: repo.name,
      html_url: repo.html_url,
      description: repo.description,
      private: repo.private,
      archived: repo.archived,
      fork: repo.fork,
      language: repo.language,
      pushed_at: repo.pushed_at,
      updated_at: repo.updated_at,
      created_at: repo.created_at,
      default_branch: repo.default_branch,
      owner: repo.owner,
      latest_commit_author: pickAuthor(repo, commit),
      latest_commit_sha: commit?.sha || null,
      latest_commit_date: commit?.commit?.author?.date || repo.pushed_at || repo.updated_at,
    });
  }

  enriched.sort((a, b) => new Date(b.pushed_at || b.updated_at) - new Date(a.pushed_at || a.updated_at));

  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, `${JSON.stringify(enriched, null, 2)}\n`);

  console.log(`Wrote ${enriched.length} repositories to ${outputPath}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
