defmodule PhoenixKitEntities.Errors do
  @moduledoc """
  Central mapping from error atoms (returned by the Entities module's
  public API) to translated human-readable strings.

  Keeping the API layer locale-agnostic means callers can pattern-match
  on atoms and decide their own presentation. Anything user-facing
  (flash messages, error banners) goes through `message/1` which wraps
  each mapping in `gettext/1` using this package's own
  `PhoenixKitEntities.Gettext` backend.

  ## Supported reason shapes

    * plain atoms — `:cannot_remove_primary`, `:not_multilang`,
      `:entity_not_found`, etc.
    * tagged tuples — `{:invalid_field_type, type}`,
      `{:requires_options, type}`, `{:missing_required_keys, [keys]}`,
      `{:user_entity_limit_reached, max}`, and the mirror importer's
      reasons (`{:rolled_back, reason}`, `{:validation_failed,
      changeset}`, `{:broken_links, links}`, …). The dynamic part is
      interpolated via `gettext` bindings so the wording lives in this
      package's own `.po` files.
    * strings — passed through unchanged (legacy / pre-existing
      messages already translated at the call site)
    * anything else — rendered as `"Unexpected error: <inspect>"` via
      gettext so nothing silently surfaces a raw struct

  ## Example

      iex> PhoenixKitEntities.Errors.message(:cannot_remove_primary)
      "Cannot remove the primary language."

      iex> PhoenixKitEntities.Errors.message({:invalid_field_type, "blob"})
      "Invalid field type: blob"
  """

  use Gettext, backend: PhoenixKitEntities.Gettext

  @typedoc """
  Plain atoms returned by the Entities public API.
  """
  @type error_atom ::
          :cannot_remove_primary
          | :not_multilang
          | :entity_not_found
          | :not_found
          | :invalid_format
          | :unexpected
          | :already_trashed
          | :not_trashed
          | :referenced_by_external
          | :has_children
          | :missing_target_entity
          | :relations_not_allowed
          | :managed_blueprint
          | :locked_key
          | :no_delete_guard
          | :delete_guard_error
          | :status_mismatch
          | :too_many_uuids

  @typedoc """
  Tagged tuples carrying interpolation context.
  """
  @type tagged_error ::
          {:invalid_field_type, String.t()}
          | {:requires_options, String.t()}
          | {:missing_required_keys, [String.t()]}
          | {:user_entity_limit_reached, non_neg_integer()}
          | {:rolled_back, term()}
          | {:write_failed, term()}
          | {:refused, term()}
          | {:validation_failed, Ecto.Changeset.t()}
          | {:broken_links, list()}
          | {:file_not_found, String.t()}
          | {:entity_not_found, String.t(), term()}

  @doc """
  Translates an error reason (atom, tagged tuple, or binary) into a
  user-facing string via gettext.
  """
  @spec message(term()) :: String.t()
  def message(:cannot_remove_primary), do: gettext("Cannot remove the primary language.")
  def message(:not_multilang), do: gettext("Multi-language support is not enabled.")
  def message(:entity_not_found), do: gettext("Entity not found.")
  def message(:not_found), do: gettext("Record not found.")
  def message(:invalid_format), do: gettext("Invalid format.")
  def message(:unexpected), do: gettext("An unexpected error occurred.")
  def message(:already_trashed), do: gettext("This record is already in the trash.")
  def message(:not_trashed), do: gettext("This record is not in the trash.")

  def message(:referenced_by_external) do
    gettext(
      "Cannot permanently delete: this record is referenced by other tables in the parent application. Restore it or remove the references first."
    )
  end

  def message(:has_children) do
    gettext(
      "Cannot permanently delete: this record has child records. Reassign or delete its children first."
    )
  end

  def message(:missing_target_entity), do: gettext("Relation field requires a target entity")

  def message(:relations_not_allowed),
    do: gettext("Relation fields are turned off in the Entities settings.")

  def message(:managed_blueprint) do
    gettext(
      "This blueprint is managed by another module: its slug and status cannot be changed here."
    )
  end

  def message(:locked_key),
    do: gettext("This setting is locked by the module that manages the blueprint.")

  def message(:no_delete_guard) do
    gettext("This blueprint is managed by another module and cannot be deleted here.")
  end

  def message(:delete_guard_error) do
    gettext("The module that manages this blueprint could not confirm it is safe to delete.")
  end

  def message(:status_mismatch) do
    gettext("This record was changed in another session. Reload and try again.")
  end

  def message(:too_many_uuids), do: gettext("Too many records in one request.")

  # The mirror importer's reasons. A wrapper names what happened to the
  # run; the reason inside it names why.
  def message({:rolled_back, reason}) do
    gettext("Nothing was imported: %{reason}", reason: message(reason))
  end

  def message({:write_failed, reason}), do: message(reason)
  def message({:refused, reason}), do: message(reason)

  def message({:validation_failed, %Ecto.Changeset{} = changeset}) do
    gettext("a record is not valid (%{errors})", errors: changeset_errors(changeset))
  end

  def message({:broken_links, links}) when is_list(links) do
    gettext("%{count} record(s) link to records that do not exist", count: length(links))
  end

  def message({:file_not_found, name}) when is_binary(name) do
    gettext("no export file for '%{name}'", name: name)
  end

  def message({:entity_not_found, name, _slug}) when is_binary(name) do
    gettext("entity '%{name}' does not exist", name: name)
  end

  def message(%Ecto.Changeset{} = changeset) do
    gettext("a record is not valid (%{errors})", errors: changeset_errors(changeset))
  end

  def message({:invalid_field_type, type}) when is_binary(type) do
    gettext("Invalid field type: %{type}", type: type)
  end

  def message({:requires_options, type}) when is_binary(type) do
    gettext("Field type '%{type}' requires options", type: type)
  end

  def message({:missing_required_keys, keys}) when is_list(keys) do
    gettext("Missing required keys: %{keys}", keys: Enum.join(keys, ", "))
  end

  def message({:user_entity_limit_reached, max}) when is_integer(max) do
    gettext("You have reached the maximum limit of %{max} entities", max: max)
  end

  def message(reason) when is_binary(reason), do: reason

  def message(reason) do
    gettext("Unexpected error: %{reason}", reason: inspect(reason))
  end

  # Field names and already-translated messages only — never the values.
  #
  # Bindings are matched by name, never through `String.to_existing_atom/1`:
  # a message can carry user-typed text (a field label from an imported
  # file) that already contains a `%{word}`, and no atom need exist for it.
  # A placeholder with no binding stays as written.
  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r/%{(\w+)}/, message, &binding_text(&1, &2, opts))
    end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field}: #{messages |> List.flatten() |> Enum.join(", ")}"
    end)
  end

  defp binding_text(placeholder, key, opts) do
    case Enum.find(opts, fn {name, _value} -> to_string(name) == key end) do
      {_name, value} -> to_string(value)
      nil -> placeholder
    end
  end
end
