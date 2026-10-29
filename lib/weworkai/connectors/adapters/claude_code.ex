defmodule Weworkai.Connectors.Adapters.ClaudeCode do
  @behaviour Weworkai.Connectors.Adapter

  alias Weworkai.Connectors.ClaudeBridge

  @impl true
  def label, do: "Claude Code"

  @impl true
  def avatar, do: "/images/connectors/claude_code.svg"

  @impl true
  def auth_method, do: :local_session

  @impl true
  def authenticate do
    case ClaudeBridge.auth_status() do
      {:ok, %{"loggedIn" => true} = status} ->
        {:ok, Map.take(status, ~w(email orgName subscriptionType authMethod))}

      {:ok, _} ->
        {:error, "Claude Code is not logged in. Run `claude auth login` on your computer."}

      {:error, message} ->
        {:error, message}
    end
  end

  @impl true
  def start_session(spec) do
    body = %{
      name: spec.name,
      cwd: spec.folder,
      model: spec.model,
      effort: spec.effort,
      profile: spec.profile,
      systemPrompt: spec.system_prompt,
      prompt: spec.task,
      jsonSchema: spec.json_schema,
      resume: spec.resume,
      fork: spec.fork,
      attachments: attachments(spec.attachments)
    }

    with {:ok, %{"id" => id, "claudeSessionId" => claude_session_id}} <-
           ClaudeBridge.start_session(body) do
      {:ok, %{id: id, claude_session_id: claude_session_id}}
    end
  end

  defp attachments(nil), do: nil

  defp attachments(%{folder: folder, files: files}) do
    %{
      folder: folder,
      files: Enum.map(files, &%{name: &1.name, content: Base.encode64(&1.content)})
    }
  end

  @impl true
  def list_sessions do
    with {:ok, %{"sessions" => sessions}} <- ClaudeBridge.sessions() do
      {:ok,
       Enum.map(
         sessions,
         &%{
           id: &1["id"],
           status: status(&1["status"]),
           last_event_at: last_event_at(&1["lastEventAt"])
         }
       )}
    end
  end

  # A bridge from before lastEventAt existed doesn't say.
  defp last_event_at(nil), do: nil
  defp last_event_at(iso8601), do: datetime(iso8601)

  defp datetime(iso8601) do
    {:ok, at, _offset} = DateTime.from_iso8601(iso8601)
    at
  end

  @impl true
  def session(id) do
    with {:ok, session} <- ClaudeBridge.session(id) do
      {:ok,
       %{
         id: session["id"],
         status: status(session["status"]),
         output: session["output"],
         result: session["result"],
         structured: session["structured"],
         claude_session_id: session["claudeSessionId"],
         usage: usage(session["usage"]),
         tools: tools(session["tools"])
       }}
    end
  end

  # A bridge from before tool usage was reported.
  defp tools(nil), do: nil

  defp tools(%{"available" => available} = tools) do
    %{
      available_tools: available["tools"],
      skills: available["skills"],
      host_tools: available["hostTools"],
      shared: available["sharedClaude"],
      calls: tools["calls"],
      skills_used: tools["skills"],
      host_calls: Enum.map(tools["hostCalls"], &%{tool: &1["tool"], command: &1["command"]})
    }
  end

  # A bridge from before usage was reported, or a run without a result yet.
  defp usage(nil), do: nil

  defp usage(usage) do
    %{
      input_tokens: usage["inputTokens"],
      output_tokens: usage["outputTokens"],
      cache_read_tokens: usage["cacheReadTokens"],
      cache_creation_tokens: usage["cacheCreationTokens"],
      cost_usd: usage["costUsd"],
      duration_ms: usage["durationMs"],
      turns: usage["turns"]
    }
  end

  @impl true
  def stop_session(id) do
    with {:ok, _} <- ClaudeBridge.stop_session(id), do: :ok
  end

  @impl true
  def create_worktree(repo, name) do
    with {:ok, %{"path" => path, "branch" => branch} = worktree} <-
           ClaudeBridge.create_worktree(repo, name) do
      # A bridge from before headless worktrees sends no repositories.
      {:ok,
       %{
         path: path,
         branch: branch,
         base: worktree["base"],
         repositories: worktree["repositories"] || []
       }}
    end
  end

  @impl true
  def host_tools do
    case ClaudeBridge.host_tools() do
      {:ok, %{"hostTools" => tools, "claudeHome" => shared, "recent" => recent}} ->
        {:ok,
         %{
           tools:
             Enum.map(
               tools,
               &%{
                 name: &1["name"],
                 description: &1["description"],
                 installed: &1["installed"],
                 logged_in: &1["loggedIn"],
                 account: &1["account"]
               }
             ),
           shared: Enum.map(shared, &%{name: &1["name"], items: &1["items"]}),
           recent:
             Enum.map(
               recent,
               &%{
                 at: datetime(&1["at"]),
                 session_name: &1["name"],
                 folder: &1["cwd"],
                 tool: &1["tool"],
                 command: &1["command"]
               }
             )
         }}

      {:ok, _other} ->
        {:error, "Claude bridge is outdated. Restart `bin/claude_bridge`."}

      {:error, message} ->
        {:error, message}
    end
  end

  @impl true
  def worktree_diff(path) do
    with {:ok, %{"diff" => diff}} <- ClaudeBridge.worktree_diff(path), do: {:ok, diff}
  end

  defp status("running"), do: :working
  defp status("done"), do: :done
  defp status("failed"), do: :failed
  defp status("stopped"), do: :stopped

  @impl true
  def model_options do
    with {:ok, %{"models" => models, "efforts" => efforts}} <- ClaudeBridge.models() do
      {:ok,
       %{
         models: Enum.map(models, &%{id: &1["id"], label: &1["label"]}),
         efforts: efforts
       }}
    end
  end
end
