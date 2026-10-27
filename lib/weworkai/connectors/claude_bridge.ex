defmodule Weworkai.Connectors.ClaudeBridge do
  @moduledoc """
  Client for `bin/claude_bridge`, which runs Claude Code agents in throwaway containers
  on the user's computer and the `git` commands their worktrees need.
  """

  @not_running "Claude bridge is not running. Start it on your computer with `bin/claude_bridge`."

  def auth_status, do: request(:get, "/auth/status")

  def models, do: request(:get, "/models")

  @doc "A 422 comes back as `{:error, {:rejected, reason}}`: the bridge refused this run as asked."
  def start_session(spec), do: request(:post, "/sessions", spec, &{:rejected, &1})

  def sessions, do: request(:get, "/sessions")

  def session(id), do: request(:get, "/sessions/#{id}")

  def stop_session(id), do: request(:post, "/sessions/#{id}/stop", %{})

  def create_worktree(repo, name), do: request(:post, "/worktrees", %{repo: repo, name: name})

  def worktree_diff(path), do: request(:post, "/worktrees/diff", %{path: path})

  @doc "The subfolders of `path`, or the folders agents may use for a blank one."
  def folders(path), do: request(:get, "/folders?" <> URI.encode_query(%{path: path}))

  defp request(method, path, body \\ nil, rejected \\ &Function.identity/1) do
    config = Application.fetch_env!(:weworkai, :claude_bridge)

    with {:ok, token} <- read_token(config[:token_path]) do
      [base_url: config[:url], auth: {:bearer, token}, retry: false, receive_timeout: 45_000]
      |> Keyword.merge(Keyword.get(config, :req_options, []))
      |> Req.new()
      |> Req.request(method: method, url: path, json: body)
      |> case do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: 401}} ->
          {:error, "Claude bridge rejected the token. Restart the bridge."}

        {:ok, %{status: 404, body: %{"error" => "session not found"}}} ->
          {:error, :not_found}

        # An older bridge, started before this route existed.
        {:ok, %{status: 404}} ->
          {:error, "Claude bridge is outdated. Restart `bin/claude_bridge`."}

        {:ok, %{status: 422, body: %{"error" => error}}} ->
          {:error, rejected.(error)}

        {:ok, %{body: %{"error" => error}}} ->
          {:error, "Claude bridge failed: #{error}."}

        {:error, _} ->
          {:error, @not_running}
      end
    end
  end

  defp read_token(path) do
    case File.read(path) do
      {:ok, token} -> {:ok, String.trim(token)}
      {:error, _} -> {:error, @not_running}
    end
  end
end
