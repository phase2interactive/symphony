defmodule SymphonyElixir.Claude.BackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Issue

  defp test_issue(identifier) do
    %Issue{
      id: "issue-claude-#{identifier}",
      identifier: identifier,
      title: "Claude test #{identifier}",
      description: "Test description",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: []
    }
  end

  test "run_turn captures session_id from system event and returns turn_completed" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-success-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "CL-1")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-abc-123","cwd":"'$(pwd)'"}'
      printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Working on it."}]}}'
      printf '%s\\n' '{"type":"result","subtype":"success","result":"Done","session_id":"sess-abc-123","cost_usd":0.001,"duration_ms":500,"num_turns":1}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_backend: "claude",
        claude_command: claude_binary
      )

      issue = test_issue("CL-1")
      messages = []
      test_pid = self()
      on_message = fn msg -> send(test_pid, {:claude_message, msg}) end

      {:ok, session} = ClaudeBackend.start_session(workspace)
      assert {:ok, result, updated_session} = ClaudeBackend.run_turn(session, "Do the task", issue, on_message: on_message)

      assert result[:session_id] == "sess-abc-123"
      assert updated_session.session_id == "sess-abc-123"

      assert_received {:claude_message, %{event: :session_started}}
      assert_received {:claude_message, %{event: :notification}}
      assert_received {:claude_message, %{event: :turn_completed}}

      _ = messages
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn emits turn_failed and returns error for non-success result subtypes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-failure-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "CL-2")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-fail-1","cwd":"'$(pwd)'"}'
      printf '%s\\n' '{"type":"result","subtype":"error_during_execution","error":"something went wrong","session_id":"sess-fail-1","cost_usd":0,"duration_ms":100,"num_turns":0}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_backend: "claude",
        claude_command: claude_binary
      )

      issue = test_issue("CL-2")
      test_pid = self()
      on_message = fn msg -> send(test_pid, {:claude_message, msg}) end

      {:ok, session} = ClaudeBackend.start_session(workspace)
      assert {:error, {:turn_failed, payload}} = ClaudeBackend.run_turn(session, "Do the task", issue, on_message: on_message)

      assert payload["subtype"] == "error_during_execution"
      assert_received {:claude_message, %{event: :turn_failed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn returns error on turn_timeout when process stalls" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "CL-3")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-stall","cwd":"'$(pwd)'"}'
      sleep 60
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_backend: "claude",
        claude_command: claude_binary,
        codex_turn_timeout_ms: 200
      )

      issue = test_issue("CL-3")

      {:ok, session} = ClaudeBackend.start_session(workspace)
      assert {:error, :turn_timeout} = ClaudeBackend.run_turn(session, "Stall test", issue, [])
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn passes --resume with the session_id from a prior turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-resume-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "CL-4")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-args.trace")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf '%s\\n' "$*" >> "#{trace_file}"
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-resume-1","cwd":"'$(pwd)'"}'
      printf '%s\\n' '{"type":"result","subtype":"success","result":"Done","session_id":"sess-resume-1","cost_usd":0,"duration_ms":100,"num_turns":1}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_backend: "claude",
        claude_command: claude_binary
      )

      issue = test_issue("CL-4")

      # First turn — no resume
      {:ok, session} = ClaudeBackend.start_session(workspace)
      assert {:ok, _result, updated_session} = ClaudeBackend.run_turn(session, "First turn", issue, [])

      assert updated_session.session_id == "sess-resume-1"

      # Second turn — should pass --resume sess-resume-1
      assert {:ok, _result2, _session2} = ClaudeBackend.run_turn(updated_session, "Second turn", issue, [])

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      # First invocation: no --resume
      assert Enum.any?(lines, fn line -> not String.contains?(line, "--resume") end)

      # Second invocation: --resume with the captured session_id
      assert Enum.any?(lines, fn line -> String.contains?(line, "--resume sess-resume-1") end)
    after
      File.rm_rf(test_root)
    end
  end

  test "start_session rejects the workspace root as a cwd target" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_backend: "claude",
        claude_command: "claude"
      )

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _}} =
               ClaudeBackend.start_session(workspace_root)
    after
      File.rm_rf(test_root)
    end
  end

  test "stop_session is a no-op and always returns :ok" do
    session = %{session_id: "sess-noop", workspace: "/tmp/fake", metadata: %{}}
    assert :ok = ClaudeBackend.stop_session(session)
  end
end
