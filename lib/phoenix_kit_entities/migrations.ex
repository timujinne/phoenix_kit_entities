defmodule PhoenixKitEntities.Migrations do
  @moduledoc """
  Module-owned migration chain for the entities tables (`phoenix_kit_entities`,
  `phoenix_kit_entity_data`). V1 is purely adoptive: core's V135 (+V169) still
  creates the same tables, so every statement is idempotent and name-identical
  to core's objects (authority: the live V182 schema). The floor is core's
  **V169** — first shipped in `phoenix_kit 2.4.0` — which is what makes
  `phoenix_kit_entity_data.created_by_uuid` nullable; an older core still has
  it `NOT NULL`, which this chain's adopted shape (below) does not match. The
  `pkn_schema:<N>` marker on `phoenix_kit_entities` is the version; `down/1`
  only unstamps. Protocol: phoenix_kit_hello_world README, "Adopting a table
  core already creates (extraction)".

  Core's v169 both drops and re-adds `NOT NULL` on
  `phoenix_kit_entity_data.created_by_uuid` (v169.ex:77 vs :200); the live
  schema (authority for this chain) has it nullable, so `created_by_uuid` is
  adopted here without `NOT NULL`.
  """

  use Ecto.Migration

  @current_version 1
  @marker_prefix "pkn_schema:"
  @version_table "phoenix_kit_entities"

  @doc "The chain version this code ships."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pkn_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  The applied chain version, read INSIDE a migration (uses `Ecto.Migration`'s
  `repo()`, so it raises outside migration context — `migrated_version_runtime/1`
  is the caller-safe form).
  """
  @spec migrated_version(keyword() | map()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    prefix = validated_prefix(opts)
    %{rows: rows} = repo().query!(marker_query(), [prefix])
    rows |> List.first() |> marker_to_version()
  end

  @doc """
  The applied chain version, read OUTSIDE a migration — the protocol shape
  `mix phoenix_kit.status` / `mix phoenix_kit.update` call.

  A marker-less table (or one carrying someone else's prose comment) reads as
  `0`: the pre-chain, core-baseline shape. An unusable prefix RAISES rather
  than reporting `0` — "not installed" and "you gave me a prefix I cannot
  query" must not look the same to the update task. Everything else degrades
  to `0`; `catch :exit` matters as much as `rescue`, because a dead connection
  pool exits rather than raising.
  """
  @spec migrated_version_runtime(keyword() | map()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    case PhoenixKit.RepoHelper.repo().query(marker_query(), [prefix]) do
      {:ok, %{rows: rows}} -> rows |> List.first() |> marker_to_version()
      _ -> 0
    end
  rescue
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc "Adopts (or, on a core baseline that no longer ships them, creates) the tables. Idempotent."
  @spec up(keyword() | map()) :: :ok
  def up(opts \\ []), do: opts |> validated_prefix() |> up_statements() |> Enum.each(&execute/1)

  @doc """
  Rolls the marker back to `:version` in `opts` (default `0`). Never drops a
  table or a row — see the moduledoc.
  """
  @spec down(keyword() | map()) :: :ok
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    prefix |> down_statements(target_version(opts)) |> Enum.each(&execute/1)
  end

  @doc "The SQL `up/1` executes, as data (so the shape can be test-pinned)."
  @spec up_statements(String.t()) :: [String.t()]
  def up_statements(prefix \\ "public") do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_entities (
          name character varying(255) NOT NULL,
          display_name character varying(255) NOT NULL,
          display_name_plural character varying(255),
          description text,
          icon character varying(255),
          status character varying(255) DEFAULT 'draft'::character varying NOT NULL,
          fields_definition jsonb DEFAULT '[]'::jsonb NOT NULL,
          settings jsonb,
          date_created timestamp with time zone DEFAULT now() NOT NULL,
          date_updated timestamp with time zone DEFAULT now() NOT NULL,
          uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
          created_by_uuid uuid NOT NULL,
          "position" integer DEFAULT 0
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_entity_data (
          title character varying(255) NOT NULL,
          slug character varying(255),
          status character varying(255) DEFAULT 'draft'::character varying NOT NULL,
          data jsonb DEFAULT '{}'::jsonb NOT NULL,
          metadata jsonb,
          date_created timestamp with time zone DEFAULT now() NOT NULL,
          date_updated timestamp with time zone DEFAULT now() NOT NULL,
          uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
          created_by_uuid uuid,
          entity_uuid uuid NOT NULL,
          "position" integer,
          parent_uuid uuid
      )
      """,
      constraint_guard(
        prefix,
        "phoenix_kit_entities",
        "phoenix_kit_entities_pkey",
        "ALTER TABLE #{p}phoenix_kit_entities ADD CONSTRAINT phoenix_kit_entities_pkey PRIMARY KEY (uuid)"
      ),
      constraint_guard(
        prefix,
        "phoenix_kit_entity_data",
        "phoenix_kit_entity_data_pkey",
        "ALTER TABLE #{p}phoenix_kit_entity_data ADD CONSTRAINT phoenix_kit_entity_data_pkey PRIMARY KEY (uuid)"
      ),
      constraint_guard(
        prefix,
        "phoenix_kit_entity_data",
        "fk_entity_data_entity_uuid",
        "ALTER TABLE #{p}phoenix_kit_entity_data ADD CONSTRAINT fk_entity_data_entity_uuid FOREIGN KEY (entity_uuid) REFERENCES #{p}phoenix_kit_entities(uuid) ON DELETE CASCADE"
      ),
      constraint_guard(
        prefix,
        "phoenix_kit_entity_data",
        "phoenix_kit_entity_data_parent_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_entity_data ADD CONSTRAINT phoenix_kit_entity_data_parent_uuid_fkey FOREIGN KEY (parent_uuid) REFERENCES #{p}phoenix_kit_entity_data(uuid)"
      ),
      "CREATE INDEX IF NOT EXISTS phoenix_kit_entities_created_by_uuid_idx ON #{p}phoenix_kit_entities USING btree (created_by_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_entities_name_uidx ON #{p}phoenix_kit_entities USING btree (name)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_entities_status_idx ON #{p}phoenix_kit_entities USING btree (status)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_entities_uuid_idx ON #{p}phoenix_kit_entities USING btree (uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_entity_data_created_by_uuid_idx ON #{p}phoenix_kit_entity_data USING btree (created_by_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_entity_data_entity_position_idx ON #{p}phoenix_kit_entity_data USING btree (entity_uuid, \"position\")",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_entity_data_entity_uuid_idx ON #{p}phoenix_kit_entity_data USING btree (entity_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_entity_data_parent_index ON #{p}phoenix_kit_entity_data USING btree (parent_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_entity_data_slug_idx ON #{p}phoenix_kit_entity_data USING btree (slug)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_entity_data_status_idx ON #{p}phoenix_kit_entity_data USING btree (status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_entity_data_title_idx ON #{p}phoenix_kit_entity_data USING btree (title)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_entity_data_uuid_idx ON #{p}phoenix_kit_entity_data USING btree (uuid)",
      "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{@current_version}'"
    ]
  end

  @doc "The SQL `down/1` executes, as data (marker bookkeeping only)."
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0) when is_integer(target) and target >= 0 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target > 0,
      do: ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"],
      else: ["COMMENT ON TABLE #{p}#{@version_table} IS NULL"]
  end

  # `:version` is read from both shapes `validated_prefix/1` accepts. Core's own
  # migrator threads a MAP of options through its chain, so a map-shaped call
  # here would otherwise validate its prefix fine and then silently unstamp to
  # 0 — a rollback to the wrong version, from a caller that asked for the right
  # one.
  defp target_version(opts) when is_list(opts), do: Keyword.get(opts, :version, 0)

  defp target_version(%{version: version}) when is_integer(version) and version >= 0, do: version

  defp target_version(_), do: 0

  defp constraint_guard(prefix, table, conname, alter_stmt) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{conname}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        #{alter_stmt};
      END IF;
    END
    $$
    """
  end

  defp marker_query do
    """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """
  end

  defp marker_to_version([@marker_prefix <> n]) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  defp marker_to_version(_), do: 0

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
