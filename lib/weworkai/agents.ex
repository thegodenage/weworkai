defmodule Weworkai.Agents do
  use Ash.Domain, otp_app: :weworkai, extensions: [AshPhoenix]

  @doc """
  What the agent still lacks to run, model first: `:model`, `:connector`, or nil when it
  can run. Needs `connector_link` loaded. The `:runnable` read filters on the same.
  """
  def missing_setup(%{model: nil}), do: :model
  def missing_setup(%{connector_link: nil}), do: :connector
  def missing_setup(_agent), do: nil

  resources do
    resource Weworkai.Agents.Agent do
      define :list_agents, action: :read
      define :get_agent, action: :read, get_by: [:id]
      define :create_agent, action: :create
      define :configure_agent, action: :configure
      define :assign_agent_role, action: :assign_role
      define :runnable_agents, action: :runnable
    end

    resource Weworkai.Agents.AgentRun do
      define :active_runs, action: :active
      define :get_run, action: :read, get_by: [:id]
      define :search_runs, action: :search, args: [:pattern]
      define :start_run, action: :start
      define :stop_run, action: :stop
    end

    resource Weworkai.Agents.RunUsage do
      define :record_usage, action: :record
      define :task_usage, action: :for_task, args: [:task_id]
      define :usage_since, action: :since, args: [:since]
      define :agent_usage_since, action: :for_agent_since, args: [:agent_id, :since]
    end

    resource Weworkai.Agents.AgentConnector do
      define :link_connector, action: :link, args: [:agent_id, :connector_id]
    end
  end
end
