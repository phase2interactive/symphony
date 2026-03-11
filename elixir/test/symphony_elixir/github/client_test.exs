defmodule SymphonyElixir.GitHub.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Tracker.Issue

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_github_workflow!(path, overrides \\ []) do
    write_workflow_file!(
      path,
      Keyword.merge(
        [
          tracker_kind: "github",
          tracker_api_token: nil,
          tracker_project_slug: nil,
          tracker_token: "ghp_test_token",
          tracker_repo: "owner/repo"
        ],
        overrides
      )
    )
  end

  # Inject a custom get function into application config for test isolation.
  defp with_get_fun(fun, test_fn) do
    Application.put_env(:symphony_elixir, :github_get_fun, fun)

    try do
      test_fn.()
    after
      Application.delete_env(:symphony_elixir, :github_get_fun)
    end
  end

  defp with_post_fun(fun, test_fn) do
    Application.put_env(:symphony_elixir, :github_post_fun, fun)

    try do
      test_fn.()
    after
      Application.delete_env(:symphony_elixir, :github_post_fun)
    end
  end

  defp with_patch_fun(fun, test_fn) do
    Application.put_env(:symphony_elixir, :github_patch_fun, fun)

    try do
      test_fn.()
    after
      Application.delete_env(:symphony_elixir, :github_patch_fun)
    end
  end

  defp github_issue_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 42,
        "title" => "Fix the bug",
        "body" => "This is the description",
        "html_url" => "https://github.com/owner/repo/issues/42",
        "state" => "open",
        "labels" => [%{"name" => "Todo"}],
        "assignee" => %{"login" => "dev-user"},
        "created_at" => "2024-01-15T10:00:00Z",
        "updated_at" => "2024-01-16T12:00:00Z"
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # fetch_candidate_issues/0
  # ---------------------------------------------------------------------------

  test "fetch_candidate_issues returns issues for active_states labels" do
    write_github_workflow!(Workflow.workflow_file_path())

    # Each active-state label is fetched separately (GitHub labels param is AND).
    # Return the fixture only for the "Todo" label query, empty for others.
    with_get_fun(
      fn url, _headers ->
        assert url =~ "/repos/owner/repo/issues"

        if url =~ "labels=Todo" do
          {:ok, %{status: 200, body: [github_issue_fixture()]}}
        else
          {:ok, %{status: 200, body: []}}
        end
      end,
      fn ->
        assert {:ok, [%Issue{} = issue]} = Client.fetch_candidate_issues()
        assert issue.id == "42"
        assert issue.identifier == "#42"
        assert issue.title == "Fix the bug"
        assert issue.description == "This is the description"
        assert issue.state == "Todo"
        assert issue.branch_name =~ "42-fix-the-bug"
        assert issue.url == "https://github.com/owner/repo/issues/42"
        assert issue.assignee_id == "dev-user"
        assert %DateTime{} = issue.created_at
        assert %DateTime{} = issue.updated_at
      end
    )
  end

  test "fetch_candidate_issues picks active-state label even when not first" do
    write_github_workflow!(Workflow.workflow_file_path())

    issue_with_extra_labels =
      github_issue_fixture(%{
        "labels" => [%{"name" => "bug"}, %{"name" => "enhancement"}, %{"name" => "Todo"}]
      })

    with_get_fun(
      fn _url, _headers ->
        {:ok, %{status: 200, body: [issue_with_extra_labels]}}
      end,
      fn ->
        assert {:ok, [%Issue{} = issue]} = Client.fetch_candidate_issues()
        assert issue.state == "Todo"
        assert issue.labels == ["bug", "enhancement", "Todo"]
      end
    )
  end

  test "fetch_candidate_issues returns error when token is missing" do
    write_github_workflow!(Workflow.workflow_file_path(), tracker_token: nil)
    System.delete_env("SYMPHONY_GITHUB_TOKEN")

    assert {:error, :missing_github_token} = Client.fetch_candidate_issues()
  end

  test "fetch_candidate_issues returns error when repo is missing" do
    write_github_workflow!(Workflow.workflow_file_path(), tracker_repo: nil)

    assert {:error, :missing_github_repo} = Client.fetch_candidate_issues()
  end

  test "fetch_candidate_issues paginates through multiple pages" do
    write_github_workflow!(Workflow.workflow_file_path())

    page1 = Enum.map(1..100, fn n -> github_issue_fixture(%{"number" => n, "title" => "Issue #{n}"}) end)
    page2 = [github_issue_fixture(%{"number" => 101, "title" => "Issue 101"})]

    # Track per-label page counts to test pagination within a single label
    call_count = :counters.new(1, [:atomics])

    with_get_fun(
      fn url, _headers ->
        if url =~ "labels=Todo" do
          count = :counters.get(call_count, 1) + 1
          :counters.put(call_count, 1, count)

          if count == 1 do
            {:ok, %{status: 200, body: page1}}
          else
            {:ok, %{status: 200, body: page2}}
          end
        else
          {:ok, %{status: 200, body: []}}
        end
      end,
      fn ->
        assert {:ok, issues} = Client.fetch_candidate_issues()
        assert length(issues) == 101
      end
    )
  end

  test "fetch_candidate_issues propagates HTTP error status" do
    write_github_workflow!(Workflow.workflow_file_path())

    with_get_fun(
      fn _url, _headers -> {:ok, %{status: 403, body: "Forbidden"}} end,
      fn ->
        assert {:error, {:github_api_status, 403}} = Client.fetch_candidate_issues()
      end
    )
  end

  test "fetch_candidate_issues propagates transport errors" do
    write_github_workflow!(Workflow.workflow_file_path())

    with_get_fun(
      fn _url, _headers -> {:error, :econnrefused} end,
      fn ->
        assert {:error, {:github_api_request, :econnrefused}} = Client.fetch_candidate_issues()
      end
    )
  end

  # ---------------------------------------------------------------------------
  # fetch_issues_by_states/1
  # ---------------------------------------------------------------------------

  test "fetch_issues_by_states fetches issues filtered by given labels" do
    write_github_workflow!(Workflow.workflow_file_path())

    with_get_fun(
      fn url, _headers ->
        assert url =~ "labels=In"
        {:ok, %{status: 200, body: [github_issue_fixture(%{"labels" => [%{"name" => "In Progress"}]})]}}
      end,
      fn ->
        assert {:ok, [%Issue{state: "In Progress"}]} = Client.fetch_issues_by_states(["In Progress"])
      end
    )
  end

  test "fetch_issues_by_states returns empty list for empty input" do
    write_github_workflow!(Workflow.workflow_file_path())

    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  # ---------------------------------------------------------------------------
  # fetch_issue_states_by_ids/1
  # ---------------------------------------------------------------------------

  test "fetch_issue_states_by_ids fetches each issue by number" do
    write_github_workflow!(Workflow.workflow_file_path())

    with_get_fun(
      fn url, _headers ->
        assert url =~ "/repos/owner/repo/issues/"
        {:ok, %{status: 200, body: github_issue_fixture()}}
      end,
      fn ->
        assert {:ok, [%Issue{id: "42"}]} = Client.fetch_issue_states_by_ids(["42"])
      end
    )
  end

  test "fetch_issue_states_by_ids returns empty list for empty input" do
    write_github_workflow!(Workflow.workflow_file_path())

    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "fetch_issue_states_by_ids returns error when issue not found" do
    write_github_workflow!(Workflow.workflow_file_path())

    with_get_fun(
      fn _url, _headers -> {:ok, %{status: 404, body: "Not Found"}} end,
      fn ->
        assert {:error, :issue_not_found} = Client.fetch_issue_states_by_ids(["999"])
      end
    )
  end

  # ---------------------------------------------------------------------------
  # create_comment/2
  # ---------------------------------------------------------------------------

  test "create_comment posts a comment to the issue" do
    write_github_workflow!(Workflow.workflow_file_path())

    test_pid = self()

    with_post_fun(
      fn url, body, _headers ->
        send(test_pid, {:post_called, url, body})
        {:ok, %{status: 201, body: %{}}}
      end,
      fn ->
        assert :ok = Client.create_comment("42", "Great work!")
        assert_received {:post_called, url, %{"body" => "Great work!"}}
        assert url =~ "/repos/owner/repo/issues/42/comments"
      end
    )
  end

  test "create_comment returns error on HTTP failure" do
    write_github_workflow!(Workflow.workflow_file_path())

    with_post_fun(
      fn _url, _body, _headers -> {:ok, %{status: 422, body: %{}}} end,
      fn ->
        assert {:error, {:github_api_status, 422}} = Client.create_comment("42", "comment")
      end
    )
  end

  # ---------------------------------------------------------------------------
  # update_issue_state/2 — non-terminal state (label swap)
  # ---------------------------------------------------------------------------

  test "update_issue_state swaps active label to new state without closing" do
    write_github_workflow!(Workflow.workflow_file_path())

    test_pid = self()

    with_get_fun(
      fn _url, _headers ->
        {:ok, %{status: 200, body: github_issue_fixture(%{"labels" => [%{"name" => "Todo"}]})}}
      end,
      fn ->
        with_patch_fun(
          fn url, body, _headers ->
            send(test_pid, {:patch_called, url, body})
            {:ok, %{status: 200, body: %{}}}
          end,
          fn ->
            assert :ok = Client.update_issue_state("42", "In Progress")
            assert_received {:patch_called, _url, body}
            assert "In Progress" in body["labels"]
            refute "Todo" in body["labels"]
            refute Map.has_key?(body, "state")
          end
        )
      end
    )
  end

  # ---------------------------------------------------------------------------
  # update_issue_state/2 — terminal state (close issue)
  # ---------------------------------------------------------------------------

  test "update_issue_state closes the issue when entering a terminal state" do
    write_github_workflow!(Workflow.workflow_file_path())

    test_pid = self()

    with_get_fun(
      fn _url, _headers ->
        {:ok, %{status: 200, body: github_issue_fixture(%{"labels" => [%{"name" => "In Progress"}]})}}
      end,
      fn ->
        with_patch_fun(
          fn _url, body, _headers ->
            send(test_pid, {:patch_called, body})
            {:ok, %{status: 200, body: %{}}}
          end,
          fn ->
            assert :ok = Client.update_issue_state("42", "Done")
            assert_received {:patch_called, body}
            assert body["state"] == "closed"
            assert "Done" in body["labels"]
          end
        )
      end
    )
  end

  # ---------------------------------------------------------------------------
  # graphql/3
  # ---------------------------------------------------------------------------

  test "graphql posts to GitHub GraphQL endpoint and returns body" do
    write_github_workflow!(Workflow.workflow_file_path())

    query = "query { viewer { login } }"
    variables = %{"org" => "openai"}

    assert {:ok, %{"data" => %{"viewer" => %{"login" => "dev"}}}} =
             Client.graphql(query, variables,
               request_fun: fn _url, payload, headers ->
                 assert payload["query"] == query
                 assert payload["variables"] == variables
                 assert Enum.any?(headers, fn {k, _} -> k == "Authorization" end)
                 {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "dev"}}}}}
               end
             )
  end

  test "graphql returns error on non-200 response" do
    write_github_workflow!(Workflow.workflow_file_path())

    assert {:error, {:github_api_status, 401}} =
             Client.graphql("query { viewer { login } }", %{},
               request_fun: fn _url, _payload, _headers ->
                 {:ok, %{status: 401, body: "Unauthorized"}}
               end
             )
  end
end
