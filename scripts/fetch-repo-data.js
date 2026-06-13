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

async function fetchTopContributor(repo) {
  const contributorsUrl = new URL(`https://api.github.com/repos/${org}/${repo.name}/contributors`);
  contributorsUrl.searchParams.set('per_page', '1');

  try {
    const contributors = await githubJson(contributorsUrl);
    return contributors[0] || null;
  } catch (error) {
    console.warn(`Could not read contributors for ${repo.name}: ${error.message}`);
    return null;
  }
}

function isOrgName(value) {
  return value && value.toLowerCase() === org.toLowerCase();
}

function pickAuthor(repo, commit, contributor) {
  const candidates = [
    commit?.commit?.author?.name,
    commit?.commit?.committer?.name,
    commit?.author?.login,
    commit?.committer?.login,
    contributor?.login,
    contributor?.name,
  ];

  const individual = candidates.find((candidate) => candidate && !isOrgName(candidate));

  return individual || repo.owner?.login || repo.owner?.name || 'Unknown';
}

async function main() {
  const repos = await fetchAllRepos();

  if (repos.length === 0) {
    throw new Error(
      `No repositories were returned for ${org}. Check ORG_NAME and the REPO_DASHBOARD_PAT repository access.`
    );
  }

  const enriched = [];

  for (const repo of repos) {
    const commit = await fetchLatestCommit(repo);
    const contributor = await fetchTopContributor(repo);

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
      latest_commit_author: Person Name,
      top_contributor: contributor?.login || null,
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
