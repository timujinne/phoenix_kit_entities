defmodule PhoenixKitEntities.Attachments do
  @moduledoc """
  Scope folder for file/image fields of an entity type:

      config :phoenix_kit_entities, :attachments_parent_folder, {MyApp.Media, :parent_for}

  called as `parent_for(:entity_file, actor_uuid, %{entity_name: name})` (or `/2`),
  returning `{:ok, folder_uuid}` or `nil` (no scope, today's behaviour). The
  hook contract is core's `PhoenixKit.Modules.Storage.ResourceFolders`: an
  answer that is not a uuid, or a hook that raises, throws or exits, is logged
  and treated as `nil`.

  Hosts typically find-or-create the folder inside the hook, so call this
  from a user gesture (opening the picker), never from mount/handle_params —
  a render must not write folders.
  """

  alias PhoenixKit.Modules.Storage.ResourceFolders

  @spec scope_folder(String.t(), String.t() | nil) :: String.t() | nil
  def scope_folder(entity_name, actor_uuid) do
    ResourceFolders.parent_uuid(:phoenix_kit_entities, :entity_file, actor_uuid, %{
      entity_name: entity_name
    })
  end
end
