defmodule Relay.Repo.SynchronousCommitTest do
  use Relay.DataCase, async: true

  alias Relay.Repo

  describe "OP-10 synchronous commit" do
    test "OP-10: the session commits synchronously" do
      assert Repo.query!("SHOW synchronous_commit").rows == [["on"]]
    end

    test "OP-10: no role or database setting relaxes synchronous commit" do
      relaxed =
        Repo.query!("""
        SELECT s.setrole::regrole::text, c FROM pg_db_role_setting s, unnest(s.setconfig) AS c
        WHERE c LIKE 'synchronous\\_commit=%' AND c <> 'synchronous_commit=on'
        """).rows

      assert relaxed == []
    end

    test "OP-10: the server default is synchronous" do
      assert Repo.query!(
               "SELECT boot_val, reset_val FROM pg_settings WHERE name = 'synchronous_commit'"
             ).rows ==
               [["on", "on"]]
    end
  end
end
