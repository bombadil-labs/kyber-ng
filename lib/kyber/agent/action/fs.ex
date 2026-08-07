defmodule Kyber.Agent.Action.Fs do
  @moduledoc """
  The filesystem actions (T12): `fs.read` / `fs.write` / `fs.list`, bound to
  the workspace root in the action context. Paths resolve against the root;
  a resolution landing outside it is REFUSED BY CONSTRUCTION — the boundary
  is the expanded-path prefix check in `resolve/2`, applied by every action,
  never a test-only assertion. Absolute paths and `..` escapes resolve the
  same way and fail the same check. TWO layers: the lexical check plus a
  symlink-aware realpath walk (fold from the T12 verdict, C's best
  attribute) — a symlink inside the root pointing outside cannot smuggle a
  read/write out; the walk tolerates a nonexistent tail (writes create it)
  and caps at 40 link hops.

  `fs.read` / `fs.list` are idempotent; `fs.write` is idempotent under the
  same args (create-or-update of the same content, attested by the
  `ToolResult`). The executor's answer-from-the-store rule covers
  crash-window re-fires after the `ToolResult` persists.

  The action contract: `(decoded_args, context) -> {result, status}` —
  a refusal rides a `"refused"` status, a filesystem error an `"error"`
  status; the chain always completes, the failure is recorded, never
  repaired.
  """

  @doc "Read a file under the workspace root. Args: `path`."
  @spec read(map(), map()) :: {String.t(), String.t()}
  def read(%{"path" => path}, %{workspace: root}) do
    case resolve(root, path) do
      {:ok, full} ->
        case File.read(full) do
          {:ok, content} -> {content, "ok"}
          {:error, reason} -> {"fs.read " <> path <> ": " <> format(reason), "error"}
        end

      :refused ->
        refusal(path)
    end
  end

  def read(_args, _context), do: {"fs.read: a \"path\" string argument is required", "error"}

  @doc "Write (create or update) a file under the workspace root. Args: `path`, `content`."
  @spec write(map(), map()) :: {String.t(), String.t()}
  def write(%{"path" => path, "content" => content}, %{workspace: root})
      when is_binary(content) do
    case resolve(root, path) do
      {:ok, full} ->
        with :ok <- File.mkdir_p(Path.dirname(full)),
             :ok <- File.write(full, content) do
          {"wrote " <> Integer.to_string(byte_size(content)) <> " bytes to " <> path, "ok"}
        else
          {:error, reason} -> {"fs.write " <> path <> ": " <> format(reason), "error"}
        end

      :refused ->
        refusal(path)
    end
  end

  def write(_args, _context),
    do: {"fs.write: \"path\" and \"content\" string arguments are required", "error"}

  @doc "List a directory under the workspace root (the root itself by default). Args: optional `path`."
  @spec list(map(), map()) :: {String.t(), String.t()}
  def list(args, %{workspace: root}) do
    path = Map.get(args, "path", ".")

    case resolve(root, path) do
      {:ok, full} ->
        case File.ls(full) do
          {:ok, entries} -> {format_entries(Enum.sort(entries), full), "ok"}
          {:error, reason} -> {"fs.list " <> path <> ": " <> format(reason), "error"}
        end

      :refused ->
        refusal(path)
    end
  end

  # one entry per line, directories with a trailing slash
  defp format_entries(entries, full) do
    Enum.map_join(entries, "\n", fn entry ->
      if File.dir?(Path.join(full, entry)), do: entry <> "/", else: entry
    end)
  end

  # the workspace boundary, by construction: the expanded path must be the
  # root or strictly inside it — every escape (`..`, absolute) fails here.
  # TWO layers (fold from the T12 verdict, C's best attribute): (1) lexical —
  # Path.expand under the root; (2) real — the candidate's symlink-resolved
  # path (its parent's, for writes) must also stay under the root, so a
  # symlink inside the root pointing outside cannot smuggle a read/write out
  defp resolve(root, path) when is_binary(path) do
    root = Path.expand(root)
    full = Path.expand(path, root)

    with :ok <- contained(root, full),
         :ok <- real_contained(root, full) do
      {:ok, full}
    else
      _ -> :refused
    end
  end

  defp resolve(_root, _path), do: :refused

  defp contained(root, candidate) do
    if candidate == root or String.starts_with?(candidate, root <> "/"),
      do: :ok,
      else: {:error, {:traversal, candidate}}
  end

  defp real_contained(root, candidate) do
    with {:ok, real} <- realpath(candidate) do
      if real == root or String.starts_with?(real, root <> "/"),
        do: :ok,
        else: {:error, {:traversal, real}}
    end
  end

  # a realpath that tolerates a NONEXISTENT tail (writes create it): walk the
  # path upward, resolving symlinks as they are found; nonexistent components
  # ride in the accumulator and their deepest existing ancestor resolves —
  # so a symlinked directory inside the root cannot smuggle a path outside.
  # Hand-rolled: OTP 27 dropped :file.realpath/1 (deepseek's T12 finding)
  defp realpath(path), do: realpath(path, 0)

  defp realpath(_path, hops) when hops > 40,
    do: {:error, {:traversal, :link_cycle}}

  defp realpath(path, hops) do
    case :file.read_link(String.to_charlist(path)) do
      {:ok, target} ->
        target = List.to_string(target)

        target_path =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.join(Path.dirname(path), target)

        realpath(target_path, hops + 1)

      {:error, _not_a_link} ->
        walk_up(path, [], hops)
    end
  end

  defp walk_up(path, acc, hops) do
    case :file.read_link(String.to_charlist(path)) do
      {:ok, target} ->
        target = List.to_string(target)

        target_path =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.join(Path.dirname(path), target)

        # the components BELOW this link ride the accumulator: the resolved
        # target is the directory they live in
        realpath(target_path, hops + 1) |> append(acc)

      {:error, _not_a_link} ->
        case Path.dirname(path) do
          ^path ->
            {:ok, Path.join([path | acc])}

          parent ->
            walk_up(parent, [Path.basename(path) | acc], hops)
        end
    end
  end

  # re-append the components that sat BELOW a resolved link to its real dir
  defp append({:ok, real}, acc), do: {:ok, Path.join([real | acc])}
  defp append({:error, _} = err, _acc), do: err

  defp refusal(path) do
    {"refused: " <> path <> " escapes the workspace root", "refused"}
  end

  defp format(reason), do: :file.format_error(reason) |> to_string()
end
