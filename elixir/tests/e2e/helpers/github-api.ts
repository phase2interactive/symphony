/**
 * Direct GitHub API helper for e2e reconciliation tests.
 *
 * Talks to GitHub REST API independently of Symphony, so we can
 * compare what Symphony *thinks* the state is vs what GitHub *actually* has.
 */

const GITHUB_API = "https://api.github.com";
const API_VERSION = "2022-11-28";

export interface GitHubIssue {
  number: number;
  title: string;
  state: "open" | "closed";
  labels: string[];
  html_url: string;
  assignee: string | null;
  created_at: string;
  updated_at: string;
}

export interface GitHubConfig {
  token: string;
  repo: string;
}

function getConfig(): GitHubConfig {
  const token = process.env.SYMPHONY_GITHUB_TOKEN;
  if (!token) throw new Error("SYMPHONY_GITHUB_TOKEN is not set");
  return {
    token,
    repo: "phase2interactive/symphony",
  };
}

function headers(token: string): Record<string, string> {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": API_VERSION,
  };
}

/**
 * Fetch all open issues that have any of the given labels.
 */
export async function fetchIssuesByLabels(
  labels: string[]
): Promise<GitHubIssue[]> {
  const { token, repo } = getConfig();
  const labelParam = labels.map(encodeURIComponent).join(",");
  const url = `${GITHUB_API}/repos/${repo}/issues?state=open&labels=${labelParam}&per_page=100`;

  const response = await fetch(url, { headers: headers(token) });
  if (!response.ok) {
    throw new Error(
      `GitHub API returned ${response.status}: ${await response.text()}`
    );
  }

  const body = (await response.json()) as Array<Record<string, unknown>>;
  return body.map(normalizeIssue);
}

/**
 * Fetch a single issue by number.
 */
export async function fetchIssue(issueNumber: number): Promise<GitHubIssue> {
  const { token, repo } = getConfig();
  const url = `${GITHUB_API}/repos/${repo}/issues/${issueNumber}`;

  const response = await fetch(url, { headers: headers(token) });
  if (!response.ok) {
    throw new Error(
      `GitHub API returned ${response.status} for issue #${issueNumber}`
    );
  }

  const body = (await response.json()) as Record<string, unknown>;
  return normalizeIssue(body);
}

/**
 * Fetch all open issues with active workflow labels (the same ones Symphony polls).
 */
export async function fetchActiveIssues(): Promise<GitHubIssue[]> {
  const activeStates = [
    "Todo",
    "In Progress",
    "Merging",
    "Rework",
  ];
  // Fetch each label separately since GitHub OR-matches multiple labels
  // but Symphony treats each as a separate state
  const allIssues: GitHubIssue[] = [];
  const seen = new Set<number>();

  for (const label of activeStates) {
    const issues = await fetchIssuesByLabels([label]);
    for (const issue of issues) {
      if (!seen.has(issue.number)) {
        seen.add(issue.number);
        allIssues.push(issue);
      }
    }
  }

  return allIssues;
}

function normalizeIssue(raw: Record<string, unknown>): GitHubIssue {
  const labels = (raw.labels as Array<{ name: string }>) ?? [];
  const assignee = raw.assignee as { login: string } | null;

  return {
    number: raw.number as number,
    title: raw.title as string,
    state: raw.state as "open" | "closed",
    labels: labels.map((l) => l.name),
    html_url: raw.html_url as string,
    assignee: assignee?.login ?? null,
    created_at: raw.created_at as string,
    updated_at: raw.updated_at as string,
  };
}
