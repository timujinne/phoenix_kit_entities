defmodule PhoenixKitEntities.ActivityLog do
  @moduledoc false
  # Shared activity-logging helper for entity + entity_data mutations.
  # Hands the entry to `PhoenixKit.Activity.log/1` with the "entities" module
  # key; core never raises, so a logging failure never reaches the caller.

  @module_key "entities"

  @doc """
  Logs an activity entry with `module: "entities"` injected. Always `:ok` —
  core logs a failure and returns it, and the caller's primary mutation
  isn't affected.
  """
  @spec log(map()) :: :ok
  def log(attrs) when is_map(attrs) do
    _ = PhoenixKit.Activity.log(Map.put(attrs, :module, @module_key))
    :ok
  end

  @doc """
  Runs `op_fun` and, on `{:ok, record}`, logs an activity entry built from
  `attrs_fun.(record)`. Collapses the common `case Repo.insert(...) do ...`
  shape used in each mutation path.

  `op_fun` returns `{:ok, term} | {:error, term}`; `attrs_fun` only runs on
  success.
  """
  @spec with_log((-> {:ok, term()} | {:error, term()}), (term() -> map())) ::
          {:ok, term()} | {:error, term()}
  def with_log(op_fun, attrs_fun) when is_function(op_fun, 0) and is_function(attrs_fun, 1) do
    case op_fun.() do
      {:ok, record} = ok ->
        log(attrs_fun.(record))
        ok

      {:error, _} = err ->
        err
    end
  end
end
