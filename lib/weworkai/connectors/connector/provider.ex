defmodule Weworkai.Connectors.Connector.Provider do
  use Ash.Type.Enum, values: [:claude_code]

  alias Weworkai.Connectors.Adapters

  @adapters %{claude_code: Adapters.ClaudeCode}

  def adapter(provider), do: Map.fetch!(@adapters, provider)
end
