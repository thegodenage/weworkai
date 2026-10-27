defmodule Weworkai.Organization.Employee.Kind do
  use Ash.Type.Enum, values: [:human, :agent]
end
