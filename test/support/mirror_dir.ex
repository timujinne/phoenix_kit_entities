defmodule PhoenixKitEntities.Test.MirrorDir do
  @moduledoc """
  A scratch mirror directory for a test.

  `Mirror.Storage` only honours an `entities_mirror_path` inside the parent
  app's directory and silently falls back to the default directory
  otherwise — so a test that points the setting at `System.tmp_dir!/0`
  reads and writes the shared default instead, together with every file
  earlier runs left there. `path/1` names a directory inside that boundary
  and `use!/1` refuses to continue unless `Storage` really resolves to it.
  """

  alias PhoenixKit.Settings
  alias PhoenixKitEntities.Mirror.Storage

  @doc "An in-boundary scratch directory for `name` (not created)."
  @spec path(String.t()) :: String.t()
  def path(name) do
    Storage.default_path()
    |> Path.dirname()
    |> Path.join("mirror_test")
    |> Path.join(name)
  end

  @doc """
  Empties and creates `dir`, points `entities_mirror_path` at it, and
  removes it when the test exits. Call from `setup`.
  """
  @spec use!(String.t()) :: String.t()
  def use!(dir) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    {:ok, _} = Settings.update_setting("entities_mirror_path", dir)

    case Storage.root_path() do
      ^dir -> :ok
      other -> raise "mirror directory #{dir} was not adopted; Storage resolves to #{other}"
    end

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
