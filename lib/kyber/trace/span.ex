defmodule Kyber.Trace.Span do
  @moduledoc """
  T19 span vocabulary (the design resolution's pinned shape): the six span
  kinds, the deterministic span-id scheme, and the pointer-walk that
  resolves a delta id back to its initiating `received` claim.

  Span ids are deterministic and content-derived: `"turn:"|"dispatch:"|
  "llm:"|"tool:"|"append:"|"fan:"` <> delta id — EXCEPT `:llm`, which is
  per-attempt: `"llm:"<>request_id<>"#"<>attempt` where attempt is the
  request's ToolResult count + 1 (M1 — a tool-using turn performs k+1 real
  chats under ONE request id; first-wins would silently drop chats 2..k+1).

  `resolve_received/2` is the ONE shared walk over a delta set (the same
  semantics the reactor's private `walk_to_received/2` implements — kind →
  pointer role → next delta, until a `received` claim). It is used by the
  engine's `:llm` and the executor's `:tool_exec` emitters to pin an
  explicit trace_id when the store can resolve one; every use is wrapped in
  a total guard (emitter calls must never raise — L5).
  """

  @kind_prefixes %{
    turn: "turn:",
    dispatch: "dispatch:",
    llm: "llm:",
    tool_exec: "tool:",
    store_append: "append:",
    fan_out: "fan:"
  }

  @doc "The deterministic span id for a kind + delta id (the pinned prefixes)."
  @spec span_id(atom(), binary()) :: binary()
  def span_id(kind, id) when is_binary(id) do
    @kind_prefixes[kind] <> id
  end

  @doc """
  The llm span id: per-attempt (`"llm:"<>request_id<>"#"<>attempt`) — never
  first-wins, so a tool-using turn's k+1 real chats each get their own span.
  """
  @spec llm_span_id(binary(), pos_integer()) :: binary()
  def llm_span_id(request_id, attempt) when is_binary(request_id) do
    "llm:" <> request_id <> "#" <> Integer.to_string(attempt)
  end

  @doc """
  Walk a delta set from `id` toward the initiating `received` claim (the
  reactor's walk semantics, shared): `received` -> itself; `promptRef` ->
  its promptRef pointer; `tool` -> requestRef; `call` -> call; `decides` ->
  decides. Returns the received delta id, or nil when the walk cannot
  resolve (no pointer, a cycle, or an unknown id). Never raises.
  """
  @spec resolve_received(map(), binary() | nil) :: binary() | nil
  def resolve_received(set, id) when is_map(set) and is_binary(id) do
    do_walk(set, id, MapSet.new())
  rescue
    _ -> nil
  end

  def resolve_received(_set, _id), do: nil

  defp do_walk(set, id, seen) do
    cond do
      MapSet.member?(seen, id) ->
        nil

      true ->
        case Map.get(set, id) do
          nil ->
            nil

          {claims, _sig} ->
            case kind(claims) do
              "received" -> id
              other -> walk_pointer(set, claims, other, id, seen)
            end
        end
    end
  end

  defp walk_pointer(set, claims, delta_kind, id, seen) do
    case pointer(claims, walk_role(delta_kind)) do
      {:delta, next, _ctx} -> do_walk(set, next, MapSet.put(seen, id))
      _other -> nil
    end
  end

  defp walk_role("promptRef"), do: "promptRef"
  defp walk_role("tool"), do: "requestRef"
  defp walk_role("call"), do: "call"
  defp walk_role("decides"), do: "decides"
  defp walk_role(_other), do: nil

  defp kind(%{pointers: [%{role: role} | _rest]}), do: role
  defp kind(_claims), do: nil

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end
end
