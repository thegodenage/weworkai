defmodule Weworkai.Connectors.Connector.Status do
  use Ash.Type.Enum, values: [:disconnected, :connected, :error]
end
