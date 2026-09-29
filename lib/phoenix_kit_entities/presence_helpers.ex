defmodule PhoenixKitEntities.PresenceHelpers do
  @moduledoc """
  Helper functions for collaborative editing with Phoenix.Presence.

  Provides utilities for tracking editing sessions, determining owner/spectator roles,
  and syncing state between users.
  """

  alias PhoenixKitEntities.Presence

  @doc """
  Tracks the current LiveView process in a Presence topic.

  ## Parameters

  - `type`: The resource type (`:entity` or `:data`)
  - `id`: The resource ID
  - `socket`: The LiveView socket
  - `user`: The current user struct

  ## Examples

      track_editing_session(:entity, 5, socket, user)
      # => {:ok, ref}
  """
  def track_editing_session(type, id, socket, user) do
    topic = editing_topic(type, id)

    # Only what the presence logic actually reads. Phoenix.Presence
    # broadcasts these metas in a `presence_diff` to every other
    # collaborator's LiveView, and this used to carry the whole
    # `%PhoenixKit.Users.Auth.User{}` — including `hashed_password`, since
    # `redact: true` only suppresses Inspect, not term serialization — plus
    # the user's email. The only reader of either was
    # `populate_presence_info/3`, whose three assigns nothing rendered: the
    # credentials went across the cluster to feed dead code.
    #
    # `user_uuid` decides ownership, `joined_at` orders the queue, `pid`
    # detects a dead session. Resolve display names from the DB instead.
    Presence.track(self(), topic, socket.id, %{
      user_uuid: user.uuid,
      joined_at: System.system_time(:millisecond),
      pid: self()
    })
  end

  @doc """
  Determines if the current socket is the owner (first in the presence list).

  Returns `{:owner, presences}` if this socket is the owner (or same user in different tab), or
  `{:spectator, owner_meta, presences}` if a different user is the owner.

  ## Examples

      case get_editing_role(:entity, 5, socket.id, current_user.uuid) do
        {:owner, all_presences} ->
          # I can edit!

        {:spectator, owner_metadata, all_presences} ->
          # I'm read-only, sync with owner's state
      end
  """
  def get_editing_role(type, id, socket_id, current_user_uuid) do
    presences = get_sorted_presences(type, id)

    case presences do
      [] ->
        # No one here (shouldn't happen since caller is here)
        # But treat as owner to avoid blocking
        {:owner, []}

      [{^socket_id, _meta} | _rest] ->
        # I'm first! I'm the owner
        {:owner, presences}

      [{_other_socket_id, owner_meta} | _rest] ->
        # Check if same user (different tab) or different user
        if owner_meta.user_uuid == current_user_uuid do
          # Same user, different tab - treat as owner so both tabs can edit
          {:owner, presences}
        else
          # Different user - spectator mode (FIFO locking)
          {:spectator, owner_meta, presences}
        end
    end
  end

  @doc """
  Gets all presences for a resource, sorted by join time (FIFO).

  Returns a list of tuples: `[{socket_id, metadata}, ...]`

  ## Examples

      get_sorted_presences(:entity, "019...")
      # => [
      #   {"phx-abc123", %{user_uuid: "019...", joined_at: 123456, ...}},
      #   {"phx-def456", %{user_uuid: "019...", joined_at: 123458, ...}}
      # ]
  """
  def get_sorted_presences(type, id) do
    topic = editing_topic(type, id)
    raw_presences = Presence.list(topic)

    raw_presences
    |> Enum.flat_map(fn {socket_id, %{metas: metas}} ->
      metas
      |> Enum.filter(&alive_presence?/1)
      |> case do
        [meta | _] -> [{socket_id, meta}]
        [] -> []
      end
    end)
    |> Enum.sort_by(fn {_socket_id, meta} -> meta.joined_at end)
  end

  defp alive_presence?(meta) do
    case Map.get(meta, :pid) do
      # NOTE: `Process.alive?/1` answers only for pids on THIS node — it is
      # `false` for a live process on another one. On a multi-node
      # deployment each node therefore discards the other's presences, and
      # two people can both be told they hold the lock. Phoenix.Presence
      # already reaps dead processes through its tracker, so this filter is
      # a local optimisation with a distributed cost. Left alone here: it
      # predates this branch and changing lock ownership semantics is not a
      # sweep-sized change. Recorded in dev_docs/2026-08-28-quality-sweep.md.
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> true
    end
  end

  @doc """
  All presences except the lock owner, in join order.

  Kept because it is public API — core's `making-pages-live.md` lists it
  among this module's functions, so "no callers here" was never the whole
  question. Its metadata shape did change: a meta is now `user_uuid` /
  `joined_at` / `pid`, not the whole `%User{}`, because the struct carried
  `hashed_password` to every subscriber of the topic. Read `user_uuid` and
  load what you need.
  """
  def get_spectators(type, id) do
    case get_sorted_presences(type, id) do
      [] -> []
      [_owner | spectators] -> Enum.map(spectators, fn {_socket_id, meta} -> meta end)
    end
  end

  @doc """
  How many sessions currently have this resource open for editing.
  """
  def count_editors(type, id) do
    get_sorted_presences(type, id) |> length()
  end

  @doc """
  Gets the lock owner's metadata, or nil if no one is editing.

  ## Examples

      case get_lock_owner(:entity, 5) do
        nil -> # No one editing
        meta -> # meta.user_uuid, meta.joined_at, meta.pid
      end
  """
  def get_lock_owner(type, id) do
    case get_sorted_presences(type, id) do
      [{_socket_id, meta} | _] -> meta
      [] -> nil
    end
  end

  @doc """
  Subscribes the current process to presence events for a resource.

  After subscribing, the process will receive:
  - `%Phoenix.Socket.Broadcast{event: "presence_diff", ...}` when users join/leave

  ## Examples

      subscribe_to_editing(:entity, 5)
      # Now will receive presence_diff messages
  """
  def subscribe_to_editing(type, id) do
    topic = editing_topic(type, id)
    Phoenix.PubSub.subscribe(:phoenix_kit_internal_pubsub, topic)
  end

  @doc """
  Generates the Presence topic name for a resource.

  ## Examples

      editing_topic(:entity, 5)
      # => "entity_edit:5"

      editing_topic(:data, 10)
      # => "data_edit:10"
  """
  def editing_topic(:entity, id), do: "entity_edit:#{id}"
  def editing_topic(:data, id), do: "data_edit:#{id}"
end
