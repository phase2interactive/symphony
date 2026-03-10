defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized issue representation for the Linear tracker adapter.

  This module is now a type alias for `SymphonyElixir.Tracker.Issue`. The struct
  is kept here for backward compatibility; new code should reference
  `SymphonyElixir.Tracker.Issue` directly.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: SymphonyElixir.Tracker.Issue.t()

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
