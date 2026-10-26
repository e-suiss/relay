defmodule Relay.Schema.MigrationSafetyTest do
  use ExUnit.Case, async: true

  @migrations "priv/repo/migrations"
  @committed_renames ["20261016000001_move_queue_schema.exs"]

  defp migrations,
    do:
      @migrations |> File.ls!() |> Enum.filter(&Regex.match?(~r/^\d.*\.exs$/, &1)) |> Enum.sort()

  defp source(file), do: File.read!(Path.join(@migrations, file))

  defp created_tables(sql) do
    for [_, table] <- Regex.scan(~r/CREATE TABLE (relay\.[a-z_]+)/i, sql),
        into: MapSet.new(),
        do: table
  end

  describe "OP-57 migration safety" do
    test "OP-57: excellent_migrations finds no dangerous operation outside raw SQL" do
      for file <- migrations() do
        code = source(file)

        dangers =
          code
          |> Code.string_to_quoted!()
          |> ExcellentMigrations.DangersDetector.detect_dangers(code)
          |> Keyword.delete(:raw_sql_executed)

        assert dangers == [], file
      end
    end

    test "OP-57: migrations are timestamped, uniquely numbered and descriptively named" do
      versions =
        for file <- migrations() do
          assert [_, version, name] = Regex.run(~r/^(\d{14})_([a-z][a-z0-9_]+)\.exs$/, file)
          assert String.length(name) >= 8, file
          version
        end

      assert versions == Enum.uniq(versions)
    end

    test "OP-57: raw SQL builds indexes on existing tables concurrently" do
      for file <- migrations(),
          sql = source(file),
          created = created_tables(sql),
          [_, table] <-
            Regex.scan(
              ~r/CREATE (?:UNIQUE )?INDEX (?!CONCURRENTLY)[a-z_]+ ON (relay\.[a-z_]+)/i,
              sql
            ) do
        assert MapSet.member?(created, table), "#{file}: index on #{table} must be CONCURRENTLY"
      end
    end

    test "OP-57: raw SQL adds foreign keys to existing tables NOT VALID" do
      for file <- migrations(),
          sql = source(file),
          created = created_tables(sql),
          statement <- String.split(sql, ~s(""")),
          [_, table] <- [
            Regex.run(~r/^\s*ALTER TABLE (relay\.[a-z_]+) ADD CONSTRAINT/, statement)
          ],
          statement =~ "FOREIGN KEY" do
        assert MapSet.member?(created, table) or statement =~ "NOT VALID", "#{file}: #{table}"
      end
    end

    test "OP-57: raw SQL never rewrites a table, adds a column with a non-constant default or renames in one step" do
      for file <- migrations(), sql = source(file) do
        refute sql =~ ~r/ALTER\s+COLUMN\s+\S+\s+(SET\s+DATA\s+)?TYPE/i, file

        refute sql =~
                 ~r/ADD\s+COLUMN[^,;]*\bDEFAULT\s+(?!(?:-?\d+|true|false|'[^']*')\s*(?:,|$))/im,
               file

        refute sql =~ ~r/\bVACUUM\s+FULL\b|\bCLUSTER\b/i, file

        if file not in @committed_renames,
          do: refute(sql =~ ~r/\bRENAME\b/i, file)
      end
    end

    test "OP-57: raw SQL adds CHECK constraints to existing tables NOT VALID and validates them in a later migration" do
      for file <- migrations(),
          sql = source(file),
          created = created_tables(sql),
          [statement, table, name] <-
            Regex.scan(
              ~r/ALTER TABLE (relay\.[a-z_]+)\s+ADD CONSTRAINT ([a-z_]+)\s+CHECK[^;"]*/i,
              sql
            ),
          not MapSet.member?(created, table) do
        assert statement =~ "NOT VALID", "#{file}: #{name} must be added NOT VALID"

        refute sql =~ ~r/VALIDATE CONSTRAINT #{name}\b/,
               "#{file}: #{name} is validated in the same migration"

        assert Enum.any?(
                 migrations(),
                 &(&1 > file and source(&1) =~ ~r/VALIDATE CONSTRAINT #{name}\b/)
               ),
               "#{file}: #{name} is never validated"
      end
    end

    test "OP-57: raw SQL sets NOT NULL on an existing column only behind a validated CHECK" do
      for file <- migrations(),
          sql = source(file),
          created = created_tables(sql),
          [_, table, column] <-
            Regex.scan(
              ~r/ALTER TABLE (relay\.[a-z_]+)\s+ALTER COLUMN ([a-z_]+)\s+SET NOT NULL/i,
              sql
            ),
          not MapSet.member?(created, table) do
        earlier = Enum.filter(migrations(), &(&1 < file))

        assert Enum.any?(earlier, fn other ->
                 source(other) =~
                   ~r/ADD CONSTRAINT \w+\s+CHECK \(#{column} IS NOT NULL\) NOT VALID/
               end),
               "#{file}: #{table}.#{column} needs a validated CHECK (#{column} IS NOT NULL) first"
      end
    end

    test "OP-57: committed migrations are never changed; a fix is a new migration" do
      listed =
        "conformance/catalog/migrations.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.new(&{&1["file"], &1["sha256"]})

      files = migrations()
      assert Enum.sort(Map.keys(listed)) == files, "every migration is listed exactly once"

      for file <- files do
        hash = :crypto.hash(:sha256, source(file)) |> Base.encode16(case: :lower)
        assert Map.fetch!(listed, file) == hash, "#{file} changed after it was committed"
      end
    end

    test "OP-57: the queue migration runs before the application migrations" do
      [first | _] = migrations()
      assert first == "20261016000000_add_oban_jobs.exs"
      assert source(first) =~ "Oban.Migrations.up(version: 14"
    end
  end
end
