defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub REST API client for polling and updating issues.

  Reads configuration from `Config.settings!().tracker`:
  - `token` — GitHub personal access token (or `SYMPHONY_GITHUB_TOKEN` env var)
  - `repo` — `"owner/repo"` string
  - `active_states` — label names treated as active workflow states
  - `terminal_states` — label names treated as terminal states (closing the issue)
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker.Issue}

  @github_api_base "https://api.github.com"
  @github_graphql_url "https://api.github.com/graphql"
  @page_size 100

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- check_token(tracker),
         :ok <- check_repo(tracker) do
      do_fetch_by_labels(tracker.repo, tracker.active_states, tracker.token)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized = state_names |> Enum.map(&to_string/1) |> Enum.uniq()

    if normalized == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with :ok <- check_token(tracker),
           :ok <- check_repo(tracker) do
        do_fetch_by_labels(tracker.repo, normalized, tracker.token)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    if ids == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with :ok <- check_token(tracker),
           :ok <- check_repo(tracker) do
        Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
          case fetch_single_issue(tracker.repo, id, tracker.token) do
            {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, issues} -> {:ok, Enum.reverse(issues)}
          error -> error
        end
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    tracker = Config.settings!().tracker

    with :ok <- check_token(tracker),
         :ok <- check_repo(tracker) do
      url = "#{@github_api_base}/repos/#{tracker.repo}/issues/#{issue_id}/comments"
      headers = auth_headers(tracker.token)

      case request_fun().(url, %{"body" => body}, headers) do
        {:ok, %{status: status}} when status in 200..201 -> :ok
        {:ok, response} -> {:error, {:github_api_status, response.status}}
        {:error, reason} -> {:error, {:github_api_request, reason}}
      end
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker

    with :ok <- check_token(tracker),
         :ok <- check_repo(tracker),
         {:ok, current_issue} <- fetch_single_issue(tracker.repo, issue_id, tracker.token) do
      if Enum.member?(tracker.terminal_states, state_name) do
        close_issue(tracker.repo, issue_id, current_issue.labels, state_name, tracker)
      else
        swap_state_label(tracker.repo, issue_id, current_issue.labels, state_name, tracker)
      end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    tracker = Config.settings!().tracker
    payload = %{"query" => query, "variables" => variables}
    headers = auth_headers(tracker.token) ++ [{"Content-Type", "application/json"}]

    post_fun = Keyword.get(opts, :request_fun, &post_json_request/3)

    case post_fun.(@github_graphql_url, payload, headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, response} ->
        Logger.error("GitHub GraphQL request failed status=#{response.status}")
        {:error, {:github_api_status, response.status}}

      {:error, reason} ->
        Logger.error("GitHub GraphQL request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp check_token(%{token: token}) when is_binary(token), do: :ok
  defp check_token(_tracker), do: {:error, :missing_github_token}

  defp check_repo(%{repo: repo}) when is_binary(repo), do: :ok
  defp check_repo(_tracker), do: {:error, :missing_github_repo}

  defp do_fetch_by_labels(repo, labels, token) do
    label_param = Enum.join(labels, ",")
    do_fetch_page(repo, label_param, token, 1, [])
  end

  defp do_fetch_page(repo, label_param, token, page, acc) do
    url =
      "#{@github_api_base}/repos/#{repo}/issues" <>
        "?state=open&labels=#{URI.encode(label_param)}&per_page=#{@page_size}&page=#{page}"

    headers = auth_headers(token)

    case get_request_fun().(url, headers) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        issues = Enum.flat_map(body, &normalize_issue/1)
        updated_acc = acc ++ issues

        if length(body) == @page_size do
          do_fetch_page(repo, label_param, token, page + 1, updated_acc)
        else
          {:ok, updated_acc}
        end

      {:ok, response} ->
        {:error, {:github_api_status, response.status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp fetch_single_issue(repo, issue_number, token) do
    url = "#{@github_api_base}/repos/#{repo}/issues/#{issue_number}"
    headers = auth_headers(token)

    case get_request_fun().(url, headers) do
      {:ok, %{status: 200, body: body}} ->
        case normalize_issue(body) do
          [issue] -> {:ok, issue}
          [] -> {:error, :issue_not_found}
        end

      {:ok, %{status: 404}} ->
        {:error, :issue_not_found}

      {:ok, response} ->
        {:error, {:github_api_status, response.status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp close_issue(repo, issue_number, current_labels, state_name, tracker) do
    # Remove active labels, add terminal label, and close the issue
    labels_to_remove = Enum.filter(tracker.active_states, &Enum.member?(current_labels, &1))
    new_labels = (current_labels -- labels_to_remove) ++ [state_name]

    with :ok <- patch_issue(repo, issue_number, %{"state" => "closed", "labels" => new_labels}, tracker.token) do
      :ok
    end
  end

  defp swap_state_label(repo, issue_number, current_labels, state_name, tracker) do
    # Remove all active/terminal state labels, add the new one
    state_labels = tracker.active_states ++ tracker.terminal_states
    labels_to_keep = Enum.reject(current_labels, &Enum.member?(state_labels, &1))
    new_labels = labels_to_keep ++ [state_name]

    patch_issue(repo, issue_number, %{"labels" => new_labels}, tracker.token)
  end

  defp patch_issue(repo, issue_number, body, token) do
    url = "#{@github_api_base}/repos/#{repo}/issues/#{issue_number}"
    headers = auth_headers(token)

    case patch_request_fun().(url, body, headers) do
      {:ok, %{status: 200}} -> :ok
      {:ok, response} -> {:error, {:github_api_status, response.status}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp normalize_issue(issue) when is_map(issue) do
    number = issue["number"]

    case number do
      n when is_integer(n) ->
        labels = extract_label_names(issue)
        state = primary_state_label(labels)

        [
          %Issue{
            id: to_string(number),
            identifier: "##{number}",
            title: issue["title"],
            description: issue["body"],
            priority: nil,
            state: state,
            branch_name: derive_branch_name(number, issue["title"]),
            url: issue["html_url"],
            assignee_id: get_in(issue, ["assignee", "login"]),
            labels: labels,
            assigned_to_worker: true,
            created_at: parse_datetime(issue["created_at"]),
            updated_at: parse_datetime(issue["updated_at"])
          }
        ]

      _ ->
        []
    end
  end

  defp normalize_issue(_), do: []

  defp extract_label_names(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
  end

  defp extract_label_names(_), do: []

  defp primary_state_label([label | _]), do: label
  defp primary_state_label([]), do: nil

  defp derive_branch_name(number, title) when is_integer(number) and is_binary(title) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 50)

    "#{number}-#{slug}"
  end

  defp derive_branch_name(number, _title), do: to_string(number)

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp auth_headers(token) when is_binary(token) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]
  end

  defp auth_headers(_), do: []

  # Allow test injection of HTTP functions via application config
  defp get_request_fun do
    Application.get_env(:symphony_elixir, :github_get_fun, &default_get/2)
  end

  defp request_fun do
    Application.get_env(:symphony_elixir, :github_post_fun, &default_post/3)
  end

  defp patch_request_fun do
    Application.get_env(:symphony_elixir, :github_patch_fun, &default_patch/3)
  end

  defp default_get(url, headers) do
    Req.get(url, headers: headers, connect_options: [timeout: 30_000])
  end

  defp default_post(url, body, headers) do
    Req.post(url, headers: headers, json: body, connect_options: [timeout: 30_000])
  end

  defp default_patch(url, body, headers) do
    Req.patch(url, headers: headers, json: body, connect_options: [timeout: 30_000])
  end

  defp post_json_request(url, body, headers) do
    Req.post(url, headers: headers, json: body, connect_options: [timeout: 30_000])
  end
end
