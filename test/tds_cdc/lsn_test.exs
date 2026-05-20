defmodule TdsCdc.LsnTest do
  use ExUnit.Case, async: true

  alias TdsCdc.Lsn

  describe "to_hex/1" do
    test "converts a 10-byte LSN to standard hex format" do
      lsn = <<0, 0, 0, 40, 0, 0, 1, 32, 0, 1>>

      assert Lsn.to_hex(lsn) == "0x00000028:00000120:0001"
    end

    test "handles arbitrary-length binary" do
      lsn = <<255, 0>>

      assert Lsn.to_hex(lsn) == "0xFF00"
    end
  end

  describe "min_lsn_query/1" do
    test "generates correct SQL for minimum LSN" do
      assert Lsn.min_lsn_query("dbo_Users") ==
               "SELECT sys.fn_cdc_get_min_lsn('dbo_Users') AS lsn"
    end
  end

  describe "max_lsn_query/0" do
    test "generates correct SQL for maximum LSN" do
      assert Lsn.max_lsn_query() ==
               "SELECT sys.fn_cdc_get_max_lsn() AS lsn"
    end
  end

  describe "increment_lsn_query/1" do
    test "generates correct SQL to increment an LSN" do
      lsn = <<0, 0, 0, 40, 0, 0, 1, 32, 0, 1>>

      query = Lsn.increment_lsn_query(lsn)

      assert query =~ "sys.fn_cdc_increment_lsn"
      assert query =~ "00000028000001200001"
    end
  end

  describe "all_changes_query/3" do
    test "generates correct SQL for all changes query" do
      from_lsn = <<0, 0, 0, 1, 0, 0, 0, 1, 0, 1>>
      to_lsn = <<0, 0, 0, 2, 0, 0, 0, 2, 0, 2>>

      query = Lsn.all_changes_query("dbo_Users", from_lsn, to_lsn)

      assert query =~ "cdc.fn_cdc_get_all_changes_dbo_Users"
      assert query =~ "'all'"
    end
  end

  describe "compare/2" do
    test "returns :lt when first LSN is less than second" do
      lsn_a = <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>
      lsn_b = <<0, 0, 0, 2, 0, 0, 0, 0, 0, 1>>

      assert Lsn.compare(lsn_a, lsn_b) == :lt
    end

    test "returns :gt when first LSN is greater than second" do
      lsn_a = <<0, 0, 0, 2, 0, 0, 0, 0, 0, 1>>
      lsn_b = <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>

      assert Lsn.compare(lsn_a, lsn_b) == :gt
    end

    test "returns :eq when LSNs are equal" do
      lsn = <<0, 0, 0, 42, 0, 0, 1, 32, 0, 1>>

      assert Lsn.compare(lsn, lsn) == :eq
    end

    test "compares LSNs that differ only in later bytes" do
      lsn_a = <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>
      lsn_b = <<0, 0, 0, 1, 0, 0, 0, 0, 0, 2>>

      assert Lsn.compare(lsn_a, lsn_b) == :lt
    end
  end
end
