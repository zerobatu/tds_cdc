defmodule TdsCdc.CaptureTest do
  use ExUnit.Case, async: true

  alias TdsCdc.Capture

  describe "cdc_enabled_query/0" do
    test "generates SQL to check if CDC is enabled" do
      assert Capture.cdc_enabled_query() =~ "is_cdc_enabled = 1"
    end
  end

  describe "list_capture_instances_query/0" do
    test "generates SQL to list capture instances" do
      assert Capture.list_capture_instances_query() =~ "cdc.change_tables"
      assert Capture.list_capture_instances_query() =~ "capture_instance"
    end
  end

  describe "capture_instance_exists_query/1" do
    test "generates SQL to check if a capture instance exists" do
      query = Capture.capture_instance_exists_query("dbo_Users")

      assert query =~ "cdc.change_tables"
      assert query =~ "dbo_Users"
    end
  end
end