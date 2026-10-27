defmodule Weworkai.Organization do
  use Ash.Domain, otp_app: :weworkai, extensions: [AshPhoenix]

  resources do
    resource Weworkai.Organization.Employee do
      define :list_employees, action: :list

      define :list_all_employees,
        action: :read,
        default_options: [query: [sort: [name: :asc, id: :asc]]]

      define :get_employee, action: :read, get_by: [:id]
      define :search_employees, action: :search, args: [:pattern]
      define :create_employee, action: :create
      define :update_employee, action: :update
      define :destroy_employee, action: :destroy
    end
  end
end
