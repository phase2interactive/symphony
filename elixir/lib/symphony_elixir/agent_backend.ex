defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Behaviour for pluggable agent CLI backends (Codex, Claude Code, etc.).

  Implementations must handle session lifecycle and turn execution.
  The `run_turn/4` callback returns an `updated_session` so backends
  that carry state between turns (e.g. Claude's session_id) can do so
  without coupling the caller to backend internals.
  """

  alias SymphonyElixir.Config

  @callback start_session(workspace :: Path.t()) :: {:ok, session :: map()} | {:error, term()}

  @callback run_turn(session :: map(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, result :: map(), updated_session :: map()} | {:error, term()}

  @callback stop_session(session :: map()) :: :ok

  @spec adapter() :: module()
  def adapter do
    case Config.agent_backend() do
      "claude" -> SymphonyElixir.Claude.Backend
      _ -> SymphonyElixir.Codex.AppServer
    end
  end
end
