defmodule PhoenixKitEntities.MixProject do
  use Mix.Project

  @version "0.4.12"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_entities"

  def project do
    [
      app: :phoenix_kit_entities,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description:
        "Entities module for PhoenixKit — dynamic content types with flexible field schemas",
      package: package(),

      # Dialyzer
      dialyzer: [
        plt_add_apps: [:phoenix_kit, :mix],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],

      # Coverage — exclude test-support modules so the percentage tracks
      # production code, not boilerplate (DataCase, LiveCase, Test.Endpoint,
      # postgres test migration, etc.).
      test_coverage: [
        ignore_modules: [
          ~r/^PhoenixKitEntities\.Test\./,
          PhoenixKitEntities.DataCase,
          PhoenixKitEntities.LiveCase,
          PhoenixKitEntities.ActivityLogAssertions
        ]
      ],

      # Docs
      name: "PhoenixKitEntities",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :gettext]
    ]
  end

  # test/support/ is compiled only in :test so DataCase and TestRepo
  # don't leak into the published package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci",
        "test.js"
      ],

      # `node --test test/js` over the pure helpers exported from the hook
      # bundle — the same gate core runs. Node is optional tooling, so a
      # machine without it skips rather than fails; the Elixir suite is
      # still the gate.
      "test.js": &run_js_tests/1
    ]
  end

  defp run_js_tests(_args) do
    # `node --test` with no file arguments walks the CWD looking for
    # anything test-shaped, so an empty glob must skip rather than hand
    # node the whole repo (deps/ and _build/ included).
    files = Path.wildcard("test/js/*.test.cjs")

    cond do
      files == [] ->
        Mix.shell().info("[skip] no test/js/*.test.cjs files")

      System.find_executable("node") == nil ->
        Mix.shell().info("[skip] node not found — skipping test/js")

      true ->
        {output, status} = System.cmd("node", ["--test" | files], stderr_to_stdout: true)
        IO.puts(output)
        if status != 0, do: Mix.raise("JS tests failed")
    end
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit or
  # PHOENIX_KIT_AI_PATH=../phoenix_kit_ai. Unset => the published pin, so
  # mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"
    path = System.get_env(env_var, "") |> String.trim()

    cond do
      path != "" -> {app, [path: path, override: true] ++ opts}
      opts == [] -> {app, requirement}
      true -> {app, requirement, opts}
    end
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour and Settings API.
      # 1.7.214+ required: Scope.can_access_admin_area?/1 (the rename of the
      # now-`@deprecated` Scope.admin?/1) — an older core has no such function,
      # so this is an UndefinedFunctionError at runtime, not a warning.
      #
      # Kept a two-segment `~> 2.0` on purpose (see
      # test/core_pin_conformance_test.exs): PhoenixKitEntities.Migrations
      # (lib/phoenix_kit_entities/migrations.ex) adopts core's V169 shape —
      # `phoenix_kit_entity_data.created_by_uuid` nullable, first shipped in
      # phoenix_kit 2.4.0 — but narrowing this to `~> 2.4` would make
      # `mix deps.get` unsolvable for every host pairing this module with a
      # newer core minor. The V169 floor is documented on the migration
      # module's moduledoc instead.
      pk_dep(:phoenix_kit, "~> 2.0"),

      # mdex_native (pulled in transitively through phoenix_kit's mdex dep)
      # builds from source when MDEX_NATIVE_BUILD=1 is set in the
      # environment; that path requires rustler itself, not just
      # rustler_precompiled. Same declaration as phoenix_kit's own mix.exs.
      {:rustler, ">= 0.0.0", optional: true},

      # LiveView is needed for the admin pages.
      {:phoenix_live_view, "~> 1.0"},

      # Own Gettext backend for translated sidebar tabs, permission labels,
      # and admin UI — see priv/gettext/ and lib/phoenix_kit_entities/gettext.ex.
      {:gettext, "~> 1.0"},

      # Optional: add ex_doc for generating documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # Test-only HTML parser used by Phoenix.LiveViewTest under :test.
      {:lazy_html, "~> 0.1", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      # `priv/entities/` is RUNTIME OUTPUT — `Storage.write_entity/2` writes
      # exports there, and every file the repo had accumulated came from the test
      # suite. Gitignoring them is not enough: Hex globs `files:` off DISK, not
      # out of git, so an untracked-but-present file still ships. Without this,
      # consumers get a pile of bogus entity JSON in exactly the directory
      # `Storage.default_path/0` reads back.
      exclude_patterns: ["priv/entities/"]
    ]
  end

  defp docs do
    [
      main: "PhoenixKitEntities",
      source_ref: "v#{@version}",
      extras: ["guides/entities-guide.md"]
    ]
  end
end
