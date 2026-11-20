defmodule Quicksilver.Time do
  @moduledoc """
  Timestamp formatting for the wire.

  PROTOCOL.md: every timestamp is UTC, ISO-8601, with exactly three fractional
  digits (milliseconds) and a `Z` suffix, e.g. `"2026-11-19T21:04:05.123Z"`.
  """

  @doc "The current time in wire format."
  @spec now_iso() :: String.t()
  def now_iso, do: iso8601_ms(DateTime.utc_now())

  @doc """
  Formats a `DateTime` in wire format. `nil` passes through as `nil` so optional
  fields can be formatted without a branch at every call site.

  Always prints three fractional digits, even when the input has less precision.
  """
  @spec iso8601_ms(DateTime.t() | nil) :: String.t() | nil
  def iso8601_ms(nil), do: nil

  def iso8601_ms(%DateTime{} = dt) do
    dt = DateTime.shift_zone!(dt, "Etc/UTC")
    {us, _precision} = dt.microsecond
    ms = div(us, 1000)
    DateTime.to_iso8601(%{dt | microsecond: {ms * 1000, 3}})
  end
end
