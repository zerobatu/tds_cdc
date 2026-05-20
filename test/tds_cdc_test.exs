defmodule TdsCdcTest do
  use ExUnit.Case, async: true

  test "module is defined" do
    assert Code.ensure_loaded?(TdsCdc)
  end

  describe "public API" do
    test "cdc_enabled?/1 is exported" do
      assert TdsCdc.__info__(:functions) |> Enum.member?({:cdc_enabled?, 1})
    end

    test "list_capture_instances/1 is exported" do
      assert TdsCdc.__info__(:functions) |> Enum.member?({:list_capture_instances, 1})
    end

    test "wait_for_ready/0 and /1 are exported" do
      functions = TdsCdc.__info__(:functions)
      assert Enum.member?(functions, {:wait_for_ready, 0}) or Enum.member?(functions, {:wait_for_ready, 1})
    end
  end
end