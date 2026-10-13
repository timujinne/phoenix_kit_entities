defmodule PhoenixKitEntities.Events do
  @moduledoc """
  PubSub helpers for coordinating real-time entity updates.

  Provides broadcast and subscribe helpers for:

    * Entity definition lifecycle (create/update/delete)
    * Entity data lifecycle (create/update/delete)
    * Collaborative editing signals for entity + data forms

  All events are broadcast through `PhoenixKit.PubSub.Manager` so the library
  remains self-contained when embedded into host applications.
  """

  alias PhoenixKit.PubSub.Manager

  @typedoc "What identifies a form being edited: a uuid, a name, or `{:new, slug}`."
  @type record_key :: String.t() | atom() | {:new, String.t()}

  # Base topics
  @topic_entities "phoenix_kit:entities:definitions"
  @topic_data "phoenix_kit:entities:data"
  @topic_entity_forms "phoenix_kit:entities:entity_forms"
  @topic_data_forms "phoenix_kit:entities:data_forms"

  ## Subscription helpers

  @doc "Subscribe to entity definition lifecycle events."
  @spec subscribe_to_entities() :: :ok | {:error, term()}
  def subscribe_to_entities, do: Manager.subscribe(@topic_entities)

  @doc "Subscribe to entity data lifecycle events (all entities)."
  @spec subscribe_to_all_data() :: :ok | {:error, term()}
  def subscribe_to_all_data, do: Manager.subscribe(@topic_data)

  @doc "Subscribe to data lifecycle events for a specific entity."
  @spec subscribe_to_entity_data(String.t()) :: :ok | {:error, term()}
  def subscribe_to_entity_data(entity_uuid), do: Manager.subscribe(data_topic(entity_uuid))

  @doc "Subscribe to collaborative events for a specific entity form."
  @spec subscribe_to_entity_form(record_key()) :: :ok | {:error, term()}
  def subscribe_to_entity_form(form_key),
    do: Manager.subscribe(entity_form_topic(form_key))

  @doc "Subscribe to collaborative events for a specific data record form."
  @spec subscribe_to_data_form(String.t(), record_key()) :: :ok | {:error, term()}
  def subscribe_to_data_form(entity_uuid, record_key),
    do: Manager.subscribe(data_form_topic(entity_uuid, record_key))

  ## Entity definition lifecycle

  @doc "Announce a new entity definition."
  @spec broadcast_entity_created(String.t()) :: :ok | {:error, term()}
  def broadcast_entity_created(entity_uuid),
    do: broadcast(@topic_entities, {:entity_created, entity_uuid})

  @doc "Announce a changed entity definition; open record editors revalidate against it."
  @spec broadcast_entity_updated(String.t()) :: :ok | {:error, term()}
  def broadcast_entity_updated(entity_uuid),
    do: broadcast(@topic_entities, {:entity_updated, entity_uuid})

  @doc "Announce a deleted entity definition."
  @spec broadcast_entity_deleted(String.t()) :: :ok | {:error, term()}
  def broadcast_entity_deleted(entity_uuid),
    do: broadcast(@topic_entities, {:entity_deleted, entity_uuid})

  ## Entity data lifecycle

  @doc "Announce a new record, on the all-data topic and the entity's own."
  @spec broadcast_data_created(String.t(), String.t()) :: :ok | {:error, term()}
  def broadcast_data_created(entity_uuid, data_uuid) do
    message = {:data_created, entity_uuid, data_uuid}
    broadcast(@topic_data, message)
    broadcast(data_topic(entity_uuid), message)
  end

  @doc "Announce a changed record, on the all-data topic and the entity's own."
  @spec broadcast_data_updated(String.t(), String.t()) :: :ok | {:error, term()}
  def broadcast_data_updated(entity_uuid, data_uuid) do
    message = {:data_updated, entity_uuid, data_uuid}
    broadcast(@topic_data, message)
    broadcast(data_topic(entity_uuid), message)
  end

  @doc "Announce a hard-deleted record, on the all-data topic and the entity's own."
  @spec broadcast_data_deleted(String.t(), String.t()) :: :ok | {:error, term()}
  def broadcast_data_deleted(entity_uuid, data_uuid) do
    message = {:data_deleted, entity_uuid, data_uuid}
    broadcast(@topic_data, message)
    broadcast(data_topic(entity_uuid), message)
  end

  @doc "Announce that an entity's records were reordered."
  @spec broadcast_data_reordered(String.t()) :: :ok | {:error, term()}
  def broadcast_data_reordered(entity_uuid) do
    message = {:data_reordered, entity_uuid}
    broadcast(@topic_data, message)
    broadcast(data_topic(entity_uuid), message)
  end

  @doc """
  Drops every `:data_created` / `:data_updated` / `:data_deleted` message
  already queued in the calling process's mailbox.

  For subscribers whose handler ignores the payload and just reloads:
  `EntityData.bulk_delete/2` broadcasts one `:data_deleted` per row, so
  without this a 500-row "Delete forever" runs 500 full reloads in every
  open list. Call it at the top of the handler — the reload that follows
  already reflects every change the dropped messages announced.
  """
  @spec flush_data_events() :: :ok
  def flush_data_events do
    receive do
      {event, _entity_uuid, _data_uuid}
      when event in [:data_created, :data_updated, :data_deleted] ->
        flush_data_events()
    after
      0 -> :ok
    end
  end

  ## Collaborative form editing

  @doc "Send an entity form's unsaved state to the other sessions editing it."
  @spec broadcast_entity_form_change(record_key(), map(), keyword()) :: :ok | {:error, term()}
  def broadcast_entity_form_change(form_key, payload, opts \\ []) do
    broadcast(
      entity_form_topic(form_key),
      {:entity_form_change, form_key, payload, Keyword.get(opts, :source)}
    )
  end

  @doc "Send a record form's unsaved state to the other sessions editing it."
  @spec broadcast_data_form_change(String.t(), record_key(), map(), keyword()) ::
          :ok | {:error, term()}
  def broadcast_data_form_change(entity_uuid, record_key, payload, opts \\ []) do
    broadcast(
      data_form_topic(entity_uuid, record_key),
      {:data_form_change, entity_uuid, normalize_record_key(record_key), payload,
       Keyword.get(opts, :source)}
    )
  end

  ## Topic helpers

  defp data_topic(entity_uuid), do: "#{@topic_data}:#{entity_uuid}"

  defp entity_form_topic(form_key), do: "#{@topic_entity_forms}:#{form_key}"

  defp data_form_topic(entity_uuid, record_key),
    do: "#{@topic_data_forms}:#{entity_uuid}:#{normalize_record_key(record_key)}"

  defp normalize_record_key({:new, slug}), do: "new-#{slug}"
  defp normalize_record_key(record_key) when is_atom(record_key), do: Atom.to_string(record_key)

  defp normalize_record_key(record_key), do: to_string(record_key)

  defp broadcast(topic, payload), do: Manager.broadcast(topic, payload)
end
