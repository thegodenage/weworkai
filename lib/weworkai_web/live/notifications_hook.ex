defmodule WeworkaiWeb.NotificationsHook do
  @moduledoc """
  The notification bell every LiveView shares (`on_mount` of the router's live_session).

  Keeps `@notifications` (the latest few, newest first) and `@unread_count`, handles the
  bell's events (`open_notification`, `mark_all_notifications_read`) and pushes every new
  notification to the page as a `"notification"` event (toast, desktop notification).

  Notification messages and bell events stop here, so views need no clauses for them. A
  view that reacts to them too implements `c:handle_notification/2`.
  """
  use WeworkaiWeb, :verified_routes

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2, update: 3]

  alias Weworkai.{ErrorText, Notifications}
  alias Weworkai.Notifications.Notification
  alias WeworkaiWeb.NotificationComponents

  @recent_limit 8
  @toast_body_length 160

  @doc "Called after the bell's state changed: a notification was created, or some were read."
  @callback handle_notification({:created, Notification.t()} | :read, Phoenix.LiveView.Socket.t()) ::
              Phoenix.LiveView.Socket.t()
  @optional_callbacks handle_notification: 2

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Weworkai.PubSub, "notifications")

    {:cont,
     socket
     |> load()
     |> attach_hook(:notifications_info, :handle_info, &handle_info/2)
     |> attach_hook(:notifications_event, :handle_event, &handle_event/3)}
  end

  defp load(socket) do
    assign(socket,
      notifications: Notifications.recent_notifications!(@recent_limit),
      unread_count: Notifications.unread_notification_count!()
    )
  end

  defp handle_info({:notification_created, notification}, socket) do
    {:halt,
     socket
     |> update(:notifications, &Enum.take([notification | &1], @recent_limit))
     |> update(:unread_count, &(&1 + 1))
     |> push_event("notification", payload(notification))
     |> forward({:created, notification})}
  end

  # Another tab read some; read state is shared, so this bell follows.
  defp handle_info(:notifications_read, socket),
    do: {:halt, socket |> load() |> forward(:read)}

  defp handle_info(_message, socket), do: {:cont, socket}

  defp handle_event("open_notification", %{"id" => id}, socket) do
    case Notifications.get_notification(id) do
      {:ok, notification} ->
        Notifications.mark_notification_read!(notification)
        {:halt, socket |> read() |> open_task(notification)}

      # Deleted with its task meanwhile.
      {:error, _} ->
        {:halt, load(socket)}
    end
  end

  defp handle_event("mark_all_notifications_read", _params, socket) do
    Notifications.mark_all_notifications_read!()
    {:halt, read(socket)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp read(socket) do
    Phoenix.PubSub.broadcast_from(Weworkai.PubSub, self(), "notifications", :notifications_read)
    socket |> load() |> forward(:read)
  end

  defp open_task(socket, %{task_id: nil}), do: socket

  defp open_task(socket, %{task_id: task_id}),
    do: push_navigate(socket, to: ~p"/tasks/#{task_id}")

  defp forward(socket, change) do
    if function_exported?(socket.view, :handle_notification, 2),
      do: socket.view.handle_notification(change, socket),
      else: socket
  end

  defp payload(notification) do
    %{
      id: notification.id,
      kind: notification.kind,
      # The bell's own icon and tone, so a toast looks like its row.
      icon: NotificationComponents.kind_icon(notification.kind),
      tone: "tone-#{NotificationComponents.kind_tone(notification.kind)}",
      title: notification.title,
      body:
        notification.body &&
          notification.body |> ErrorText.clean() |> String.slice(0, @toast_body_length),
      url: notification.task_id && ~p"/tasks/#{notification.task_id}"
    }
  end
end
