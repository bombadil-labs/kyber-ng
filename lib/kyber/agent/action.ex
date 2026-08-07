defmodule Kyber.Agent.Action do
  @moduledoc """
  The action registry (T12): the capability surface as DATA — `%{name =>
  entry}` entries the executor maps to action modules. An entry is
  `%{description, parameters, run}`: `parameters` is the typed JSON-object
  shape (the OpenAI `parameters` shape the T11b fold already speaks), and
  `run` is a `{module, function}` tuple the executor applies with the
  decoded args and the action context. Entries are data, not code — the
  registry never holds closures (the A/B property: the stub registry's
  closures and this registry's data ride the same executor seam).

  The context (`context/1`) is resolved at boot and shared by every action:
  the workspace root the fs actions bind to (and the shell's sandboxed
  cwd), the injectable HTTP client seam, the shell timeout, and the output
  cap. It carries NO secrets — the LLM handler's key-refusal doctrine
  extends to actions: the api key is structurally absent here, and the
  shell action's environment is scrubbed.

  Idempotence (the carried determinism clause): `fs.read` / `fs.list` are
  idempotent; `fs.write` is idempotent under the same args (create-or-update
  of the same content); `sh.run` is idempotent only for pure commands;
  `http.get` is idempotent modulo the remote (a safe method); `http.post`
  is NOT idempotent by HTTP semantics. The executor's answer-from-the-store
  rule covers crash-window re-fires after the `ToolResult` persists; for
  the residual window (a crash mid-run) the gate should hold side-effecting
  actions at `prompt` / `deny`.
  """

  alias Kyber.Agent.Action.{Fs, Http, Shell}

  @default_shell_timeout 5_000
  @default_output_cap 65_536

  @type entry :: %{
          description: String.t(),
          parameters: map(),
          run: {module(), atom()}
        }

  @doc """
  The real action registry: `fs.read` / `fs.write` / `fs.list`, `sh.run`,
  `http.get` / `http.post`.
  """
  @spec registry() :: %{String.t() => entry()}
  def registry do
    %{
      "fs.read" => %{
        description: "Read a file under the workspace root and return its content.",
        parameters:
          object(
            %{
              "path" => %{
                "type" => "string",
                "description" => "Path relative to the workspace root."
              }
            },
            ["path"]
          ),
        run: {Fs, :read}
      },
      "fs.write" => %{
        description: "Write (create or update) a file under the workspace root.",
        parameters:
          object(
            %{
              "path" => %{
                "type" => "string",
                "description" => "Path relative to the workspace root."
              },
              "content" => %{"type" => "string", "description" => "The full file content."}
            },
            ["path", "content"]
          ),
        run: {Fs, :write}
      },
      "fs.list" => %{
        description: "List a directory under the workspace root (the root itself by default).",
        parameters:
          object(
            %{
              "path" => %{
                "type" => "string",
                "description" => "Directory relative to the workspace root (default the root)."
              }
            },
            []
          ),
        run: {Fs, :list}
      },
      "sh.run" => %{
        description:
          "Run a shell command with the cwd sandboxed to the workspace root, a hard " <>
            "timeout, and capped output (truncated with a marker). Non-zero exit is a status.",
        parameters:
          object(
            %{"command" => %{"type" => "string", "description" => "The command line to run."}},
            ["command"]
          ),
        run: {Shell, :run}
      },
      "http.get" => %{
        description: "Fetch a URL (http/https only; the response body is capped).",
        parameters:
          object(
            %{"url" => %{"type" => "string", "description" => "The URL to fetch."}},
            ["url"]
          ),
        run: {Http, :get}
      },
      "http.post" => %{
        description:
          "POST a body to a URL (http/https only; the request body over the cap is refused, " <>
            "the response body is capped).",
        parameters:
          object(
            %{
              "url" => %{"type" => "string", "description" => "The URL to post to."},
              "body" => %{"type" => "string", "description" => "The request body."}
            },
            ["url", "body"]
          ),
        run: {Http, :post}
      }
    }
  end

  @doc """
  The boot-resolved action context. Options: `:workspace` (required — the
  root fs actions bind to and the shell's sandboxed cwd), `:http`
  (`{module, state}`, default the stdlib `:httpc` adapter), `:shell_timeout`
  (ms, default #{@default_shell_timeout}), `:output_cap` (bytes, default
  #{@default_output_cap}).
  """
  @spec context(keyword()) :: map()
  def context(opts) do
    %{
      workspace: Keyword.fetch!(opts, :workspace),
      http: Keyword.get(opts, :http, {Kyber.Agent.HttpClient.Httpc, nil}),
      shell_timeout: Keyword.get(opts, :shell_timeout, @default_shell_timeout),
      output_cap: Keyword.get(opts, :output_cap, @default_output_cap)
    }
  end

  @doc "The truncation marker appended to capped output — never a silent truncation."
  @spec truncation_marker(non_neg_integer()) :: String.t()
  def truncation_marker(cap),
    do: "[truncated: output exceeded the " <> Integer.to_string(cap) <> "-byte cap]"

  defp object(properties, required) do
    %{"type" => "object", "properties" => properties, "required" => required}
  end
end
