defmodule Weworkai.Notifications do
  use Ash.Domain, otp_app: :weworkai

  resources do
    resource Weworkai.Notifications.Notification do
      define :notify, action: :create
      define :recent_notifications, action: :recent, args: [{:optional, :limit}]
      define :list_notifications, action: :recent, args: [:unread, {:optional, :limit}]
      define :get_notification, action: :read, get_by: [:id]
      define :unread_notification_count, action: :unread_count
      define :mark_notification_read, action: :mark_read
      define :mark_all_notifications_read, action: :mark_all_read
    end
  end
end
