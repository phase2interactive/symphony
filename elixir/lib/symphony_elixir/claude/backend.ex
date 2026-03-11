defmodule SymphonyElixir.Claude.Backend do
  @moduledoc """
  Claude Code CLI adapter for the AgentBackend behaviour.

  Each turn is a one-shot `claude -p "$CLAUDE_PROMPT" --output-format stream-json`
  invocation. Session continuity across turns is maintained via `--resume <session_id>`,
  where the session_id is captured from the `system` init event and threaded forward
  through `updated_session`.
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger
  alias SymphonyElixir.Config

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          session_id: String.t() | nil,
          workspace: Path.t(),
          metadata: map()
        }

  @impl true
  @spec start_session(Path.t()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace) do
    with :ok <- validate_workspace_cwd(workspace) do
      {:ok, %{session_id: nil, workspace: Path.expand(workspace), metadata: %{}}}
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) ::
          {:ok, map(), session()} | {:error, term()}
  def run_turn(%{session_id: session_id, workspace: workspace} = session, prompt, issue, opts) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    case start_port(workspace, prompt, session_id) do
      {:ok, port} ->
        metadata = port_metadata(port)

        emit_message(on_message, :session_started, %{session_id: session_id}, metadata)

        case stream_turn(port, on_message, Config.settings!().codex.turn_timeout_ms, metadata) do
          {:ok, result, captured_id} ->
            final_id = captured_id || session_id
            Logger.info("Claude session completed for #{issue_context(issue)} session_id=#{final_id}")
            {:ok, result, %{session | session_id: final_id, metadata: metadata}}

          {:error, reason} ->
            Logger.warning("Claude session ended with error for #{issue_context(issue)}: #{inspect(reason)}")
            emit_message(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason}, metadata)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Claude session failed to start for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, %{})
        {:error, reason}
    end
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  # --- private ---

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    workspace_path = Path.expand(workspace)
    workspace_root = Path.expand(Config.settings!().workspace.root)
    root_prefix = workspace_root <> "/"

    cond do
      workspace_path == workspace_root ->
        {:error, {:invalid_workspace_cwd, :workspace_root, workspace_path}}

      not String.starts_with?(workspace_path <> "/", root_prefix) ->
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, workspace_path, workspace_root}}

      true ->
        :ok
    end
  end

  defp start_port(workspace, prompt, session_id) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      cmd = build_command(session_id)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(cmd)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes,
            env: [{~c"CLAUDE_PROMPT", String.to_charlist(prompt)}]
          ]
        )

      {:ok, port}
    end
  end

  defp build_command(session_id) do
    base = "#{Config.claude_command()} -p \"$CLAUDE_PROMPT\" --output-format stream-json"

    resume =
      if is_binary(session_id) and session_id != "" do
        " --resume #{session_id}"
      else
        ""
      end

    model =
      case Config.claude_model() do
        nil -> ""
        m -> " --model #{m}"
      end

    perms =
      case Config.settings!().codex.approval_policy do
        "never" -> " --dangerously-skip-permissions"
        _ -> build_allowed_tools_arg()
      end

    base <> resume <> model <> perms
  end

  defp build_allowed_tools_arg do
    case Config.claude_allowed_tools() do
      [] -> ""
      tools -> " --allowedTools " <> Enum.join(tools, ",")
    end
  end

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> %{codex_app_server_pid: to_string(os_pid)}
      _ -> %{}
    end
  end

  defp stream_turn(port, on_message, timeout_ms, metadata) do
    receive_loop(port, on_message, timeout_ms, "", nil, metadata)
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, session_id, metadata) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_line(port, on_message, complete_line, timeout_ms, session_id, metadata)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, timeout_ms, pending_line <> to_string(chunk), session_id, metadata)

      {^port, {:exit_status, status}} ->
        handle_exit_status(pending_line, status, port, on_message, timeout_ms, session_id, metadata)
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_exit_status(pending_line, status, port, on_message, timeout_ms, session_id, metadata) do
    # After exit_status, drain any remaining data messages from the mailbox.
    # Erlang ports may deliver {:noeol, data} AFTER {:exit_status, _}.
    final_line = drain_pending_data(port, pending_line)
    trimmed = String.trim(final_line)

    if trimmed != "" do
      case handle_line(port, on_message, trimmed, timeout_ms, session_id, metadata) do
        {:ok, _result, _captured_id} = success -> success
        {:error, _reason} = error -> error
      end
    else
      case status do
        0 -> {:error, :port_exit_before_result}
        _ -> {:error, {:port_exit, status}}
      end
    end
  end

  defp drain_pending_data(port, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        # Complete line found; return it for processing (ignore further draining)
        pending_line <> to_string(chunk)

      {^port, {:data, {:noeol, chunk}}} ->
        drain_pending_data(port, pending_line <> to_string(chunk))
    after
      100 ->
        pending_line
    end
  end

  defp handle_line(port, on_message, line, timeout_ms, session_id, metadata) do
    case Jason.decode(line) do
      {:ok, %{"type" => "system"} = payload} ->
        # Capture session_id from the init event
        captured_id = Map.get(payload, "session_id") || session_id
        receive_loop(port, on_message, timeout_ms, "", captured_id, metadata)

      {:ok, %{"type" => "assistant"} = payload} ->
        emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)
        receive_loop(port, on_message, timeout_ms, "", session_id, metadata)

      {:ok, %{"type" => "result", "subtype" => "success"} = payload} ->
        captured_id = Map.get(payload, "session_id") || session_id
        emit_message(on_message, :turn_completed, %{payload: payload, raw: line}, metadata)
        {:ok, %{result: payload, session_id: captured_id}, captured_id}

      {:ok, %{"type" => "result"} = payload} ->
        # Any non-success result subtype (error_during_execution, etc.)
        emit_message(on_message, :turn_failed, %{payload: payload, raw: line}, metadata)
        {:error, {:turn_failed, payload}}

      {:ok, payload} ->
        emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)
        receive_loop(port, on_message, timeout_ms, "", session_id, metadata)

      {:error, _} ->
        log_non_json_line(line)
        receive_loop(port, on_message, timeout_ms, "", session_id, metadata)
    end
  end

  defp log_non_json_line(line) do
    text =
      line
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude stream output: #{text}")
      else
        Logger.debug("Claude stream output: #{text}")
      end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp default_on_message(_message), do: :ok
end
