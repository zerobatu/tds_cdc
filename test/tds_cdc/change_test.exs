defmodule TdsCdc.ChangeTest do
  use ExUnit.Case, async: true

  alias TdsCdc.Change

  describe "from_row/2" do
    test "parses an INSERT operation" do
      row = %{
        "__$operation" => 2,
        "__$start_lsn" => <<0, 0, 0, 40, 0, 0, 1, 32, 0, 1>>,
        "__$end_lsn" => nil,
        "__$seqval" => <<0, 0, 0, 40, 0, 0, 1, 32, 0, 2>>,
        "__$update_mask" => nil,
        "id" => 1,
        "name" => "test"
      }

      change = Change.from_row("dbo_Users", row)

      assert %Change{} = change
      assert change.capture_instance == "dbo_Users"
      assert change.operation == :insert
      assert change.data == %{id: 1, name: "test"}
      assert change.lsn == <<0, 0, 0, 40, 0, 0, 1, 32, 0, 1>>
    end

    test "parses a DELETE operation" do
      row = %{
        "__$operation" => 1,
        "__$start_lsn" => <<0, 0, 0, 40, 0, 0, 1, 32, 0, 1>>,
        "__$end_lsn" => nil,
        "__$seqval" => <<0, 0, 0, 40, 0, 0, 1, 32, 0, 2>>,
        "__$update_mask" => nil,
        "id" => 1,
        "name" => "test"
      }

      change = Change.from_row("dbo_Users", row)

      assert change.operation == :delete
    end

    test "parses an UPDATE operation (before image)" do
      row = %{
        "__$operation" => 3,
        "__$start_lsn" => <<0, 0, 0, 40, 0, 0, 1, 32, 0, 1>>,
        "__$end_lsn" => nil,
        "__$seqval" => <<0, 0, 0, 40, 0, 0, 1, 32, 0, 2>>,
        "__$update_mask" => <<2>>,
        "id" => 1,
        "name" => "old_name"
      }

      change = Change.from_row("dbo_Users", row)

      assert change.operation == :update
    end

    test "parses an UPDATE operation (after image)" do
      row = %{
        "__$operation" => 4,
        "__$start_lsn" => <<0, 0, 0, 40, 0, 0, 1, 32, 0, 1>>,
        "__$end_lsn" => nil,
        "__$seqval" => <<0, 0, 0, 40, 0, 0, 1, 32, 0, 2>>,
        "__$update_mask" => <<2>>,
        "id" => 1,
        "name" => "new_name"
      }

      change = Change.from_row("dbo_Users", row)

      assert change.operation == :update
    end
  end
end