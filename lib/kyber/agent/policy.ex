defmodule Kyber.Agent.Policy do
  @moduledoc """
  Epoch resolution for the T14b policy layer — pure set scans, no
  wall-clock (AC5). A `Policy` claim is a governance epoch; the current
  epoch is the unretracted claim of the family that no other unretracted
  family claim supersedes (explicit `supersedes` pointer — the operator
  clock is never a security input). A retracted claim (any `negates`
  pointer at its id) is inert — neither current nor a superseder, with no
  transitive re-pointing — so retracting the current epoch revives the
  previous unretracted one; history is never rewritten, the store only
  learns. Two unsuperseded unretracted heads is a fork: reject, never
  repair — `{:error, :forked}` and the gate fails closed.

  Matching is exact-only this slice: downcased host equality (port
  ignored), explicit scheme pointers required — an epoch with zero
  `allow_scheme` pointers refuses all gated calls, symmetric with the
  empty host list; no default schemes exist. The pre-agreed extension
  shape (`"*.suffix"`, apex excluded, downcased) is recorded, not built.
  """

  alias Kyber.Schema

  @default_family "url_policy"
  @gated_tools ["http.get", "http.post"]

  @reason_scheme "url_policy: scheme not allowed by the current epoch"
  @reason_host "url_policy: host not allowed by the current epoch"
  @reason_forked "url_policy: epoch forked (fail closed)"

  @type epoch :: %{id: String.t(), allow_hosts: [String.t()], allow_schemes: [String.t()]}

  @spec default_family() :: String.t()
  def default_family, do: @default_family

  @spec gated_tools() :: [String.t()]
  def gated_tools, do: @gated_tools

  @spec reason_scheme() :: String.t()
  def reason_scheme, do: @reason_scheme

  @spec reason_host() :: String.t()
  def reason_host, do: @reason_host

  @spec reason_forked() :: String.t()
  def reason_forked, do: @reason_forked

  @doc """
  The current epoch of a policy family: the unretracted `Policy` claim
  that is not the `supersedes` target of any other unretracted family
  claim. `:none` when the family is ungoverned (or all epochs retracted);
  `{:error, :forked}` on two live heads.
  """
  @spec current(map(), String.t()) :: {:ok, epoch()} | :none | {:error, :forked}
  def current(set, family \\ @default_family) do
    retracted = retracted_ids(set)

    live =
      for {id, {claims, _sig}} <- set,
          res = Schema.resolve(claims),
          match?(%{type: "Policy", policy: {:entity, ^family, _}}, res),
          not MapSet.member?(retracted, id),
          do: {id, res}

    superseded =
      MapSet.new(
        for {_id, res} <- live, match?({:delta, _, _}, res.supersedes) do
          {:delta, prev, _ctx} = res.supersedes
          prev
        end
      )

    case Enum.reject(live, fn {id, _res} -> MapSet.member?(superseded, id) end) do
      [] ->
        :none

      [{id, res}] ->
        {:ok, %{id: id, allow_hosts: res.allow_host, allow_schemes: res.allow_scheme}}

      _two_heads ->
        {:error, :forked}
    end
  end

  @doc """
  The exact check, scheme then host: `:allow` or `{:refuse, reason}` with
  the pinned reason sentence. `URI.parse/1` downcases the scheme but NOT
  the host (and DNS is case-insensitive), so the host is downcased before
  the exact compare — stored `allow_host` entries are already downcased.
  """
  @spec check(epoch(), String.t()) :: :allow | {:refuse, String.t()}
  def check(epoch, url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in epoch.allow_schemes -> {:refuse, @reason_scheme}
      downcase_host(uri.host) not in epoch.allow_hosts -> {:refuse, @reason_host}
      true -> :allow
    end
  end

  @doc "True iff the epoch allows the URL — `check/2` as a predicate."
  @spec matches?(epoch(), String.t()) :: boolean()
  def matches?(epoch, url), do: check(epoch, url) == :allow

  defp downcase_host(nil), do: nil
  defp downcase_host(host), do: String.downcase(host)

  # retraction-is-negation: any delta pointing `negates` at an id makes
  # that claim inert
  defp retracted_ids(set) do
    for {_id, {claims, _sig}} <- set,
        %{role: "negates", target: {:delta, target, _ctx}} <- claims.pointers,
        into: MapSet.new(),
        do: target
  end
end
