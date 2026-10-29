defmodule Weworkai.Connectors.Adapter do
  @moduledoc """
  The interface every connector provider implements.
  """

  @doc "Display name of the provider."
  @callback label() :: String.t()

  @doc "Static path of the provider's avatar image."
  @callback avatar() :: String.t()

  @doc "How the provider authenticates; one of `Weworkai.Connectors.Auth.Method`."
  @callback auth_method() :: atom()

  @doc """
  Verifies access to the provider. Returns the non-secret metadata worth keeping
  (account, organisation, plan), or a message a person can act on.
  """
  @callback authenticate() :: {:ok, map()} | {:error, String.t()}

  @doc """
  The models an agent on this provider can run with, and the effort levels it accepts,
  fetched fresh on every call.
  """
  @callback model_options() :: {:ok, model_options()} | {:error, String.t()}

  @doc """
  Starts a headless agent run on `task` in `folder`, or continues the conversation in
  `resume` with `task` as the next prompt; with `fork`, a copy of it, so the original
  conversation is left as it was. Returns the run id the other run callbacks take,
  and the id of the provider's conversation, which a later run can resume.
  `{:rejected, reason}`: the provider refused this run as asked (folder, model, …), so
  starting it again unchanged fails the same way; a plain reason may pass on a retry.
  """
  @callback start_session(session_spec()) ::
              {:ok, %{id: String.t(), claude_session_id: String.t()}}
              | {:error, {:rejected, String.t()} | String.t()}

  @doc "Runs this app started that the provider knows about, finished ones included."
  @callback list_sessions() :: {:ok, [session()]} | {:error, String.t()}

  @doc "One run with its readable log and, once finished, its result and what it used."
  @callback session(id :: String.t()) ::
              {:ok, session_with_output()} | {:error, :not_found | String.t()}

  @callback stop_session(id :: String.t()) :: :ok | {:error, :not_found | String.t()}

  @doc """
  An isolated checkout of `repo` named `name`, on its own branch from the repo's current
  commit; the same name returns the existing one. When `repo` is a folder of repositories,
  a folder with one worktree per repository (`repositories`, their folder names), each on
  the same branch.
  """
  @callback create_worktree(repo :: String.t(), name :: String.t()) ::
              {:ok, worktree()} | {:error, String.t()}

  @doc "Everything changed in a worktree since it branched off, committed or not."
  @callback worktree_diff(path :: String.t()) :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  What agents reach beyond their folder: the host CLIs that act with the user's login, the
  parts of the user's agent config they get a copy of, and the latest host-tool calls.
  """
  @callback host_tools() :: {:ok, host_tools()} | {:error, String.t()}

  @typedoc """
  `profile` decides what the agent may do (`Weworkai.Agents.Agent.Role.profile/1`).
  `json_schema` makes the run end with structured output matching it.
  `attachments` land in `<folder>/.weworkai/attachments/<attachments.folder>/` before the
  run starts, replacing what an earlier run left there.
  """
  @type session_spec :: %{
          name: String.t(),
          folder: String.t(),
          model: String.t(),
          effort: String.t() | nil,
          profile: :planner | :coder | :reviewer | :qa | :merger | :custom,
          system_prompt: String.t() | nil,
          task: String.t(),
          json_schema: map() | nil,
          resume: String.t() | nil,
          fork: boolean(),
          attachments:
            %{folder: String.t(), files: [%{name: String.t(), content: binary()}]} | nil
        }

  @typedoc "`:done`, `:failed` and `:stopped` are final."
  @type session_status :: :working | :done | :failed | :stopped
  @typedoc "`last_event_at`: when the run last wrote anything; nil when the provider can't say."
  @type session :: %{
          id: String.t(),
          status: session_status(),
          last_event_at: DateTime.t() | nil
        }
  @type session_with_output :: %{
          id: String.t(),
          status: session_status(),
          output: String.t(),
          result: String.t() | nil,
          structured: map() | nil,
          claude_session_id: String.t(),
          usage: usage() | nil,
          tools: tool_usage() | nil
        }

  @typedoc """
  What a run could use (`available_tools`, `skills`, `host_tools`, `shared`) and what it used:
  `calls` per tool, `skills_used`, and each `host_calls` command.
  """
  @type tool_usage :: %{
          available_tools: [String.t()],
          skills: [String.t()],
          host_tools: [String.t()],
          shared: [String.t()],
          calls: %{String.t() => non_neg_integer()},
          skills_used: [String.t()],
          host_calls: [%{tool: String.t(), command: String.t()}]
        }

  @type host_tools :: %{
          tools: [
            %{
              name: String.t(),
              description: String.t(),
              installed: boolean(),
              logged_in: boolean(),
              account: String.t() | nil
            }
          ],
          shared: [%{name: String.t(), items: [String.t()]}],
          recent: [
            %{
              at: DateTime.t(),
              session_name: String.t(),
              folder: String.t(),
              tool: String.t(),
              command: String.t()
            }
          ]
        }

  @typedoc "What one run used, its own turns only (not a resumed conversation's earlier ones)."
  @type usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_creation_tokens: non_neg_integer(),
          cost_usd: number(),
          duration_ms: non_neg_integer(),
          turns: non_neg_integer()
        }

  @type worktree :: %{
          path: String.t(),
          branch: String.t(),
          base: String.t() | nil,
          repositories: [String.t()]
        }

  @type model_options :: %{
          models: [%{id: String.t(), label: String.t()}],
          efforts: [String.t()]
        }
end
