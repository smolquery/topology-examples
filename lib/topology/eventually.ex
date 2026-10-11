defmodule Topology.Eventually do
  @moduledoc """
  Polls a condition until it holds, for suites whose subjects converge on
  their own time: a seal, a rollout, a ring rebuilding.
  """

  @doc "Calls `check` up to `attempts` times, `sleep_ms` apart, until it is truthy."
  @spec until((-> term()), pos_integer(), pos_integer()) :: boolean()
  def until(check, attempts, sleep_ms) do
    Enum.reduce_while(1..attempts, false, fn attempt, _acc ->
      cond do
        check.() -> {:halt, true}
        attempt == attempts -> {:halt, false}
        true -> Process.sleep(sleep_ms) && {:cont, false}
      end
    end)
  end

  @doc "`until/3`, raising `message` when the condition never holds."
  @spec until!((-> term()), pos_integer(), pos_integer(), String.t()) :: :ok
  def until!(check, attempts, sleep_ms, message) do
    if until(check, attempts, sleep_ms), do: :ok, else: raise(message)
  end
end
