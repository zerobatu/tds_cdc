defmodule TdsCdc.Persistence.FileTest do
  use ExUnit.Case, async: false

  alias TdsCdc.Persistence.File, as: FilePersistence

  setup do
    dir = Path.join(System.tmp_dir!(), "tds_cdc_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  describe "save_positions/2 and load_positions/1" do
    test "round-trips LSN positions", %{dir: dir} do
      original = Application.get_env(:tds_cdc, :persistence, [])
      Application.put_env(:tds_cdc, :persistence, path: dir)

      on_exit(fn ->
        Application.put_env(:tds_cdc, :persistence, original)
      end)

      positions = %{
        "dbo_users" => <<0, 0, 0, 42, 0, 0, 1, 32, 0, 82>>,
        "dbo_orders" => <<0, 0, 0, 100, 0, 0, 0, 1, 0, 1>>
      }

      :ok = FilePersistence.save_positions(:test_client, positions)
      {:ok, loaded} = FilePersistence.load_positions(:test_client)

      assert loaded == positions
    end

    test "returns not_found when no file exists", %{dir: dir} do
      original = Application.get_env(:tds_cdc, :persistence, [])
      Application.put_env(:tds_cdc, :persistence, path: dir)

      on_exit(fn ->
        Application.put_env(:tds_cdc, :persistence, original)
      end)

      assert {:error, :not_found} = FilePersistence.load_positions(:nonexistent_client)
    end

    test "creates directory if it doesn't exist", %{dir: dir} do
      nested = Path.join(dir, "nested/subdir")
      original = Application.get_env(:tds_cdc, :persistence, [])
      Application.put_env(:tds_cdc, :persistence, path: nested)

      on_exit(fn ->
        Application.put_env(:tds_cdc, :persistence, original)
      end)

      positions = %{"dbo_users" => <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>}
      :ok = FilePersistence.save_positions(:test_client, positions)

      {:ok, loaded} = FilePersistence.load_positions(:test_client)
      assert loaded == positions
    end

    test "file contains human-readable JSON", %{dir: dir} do
      original = Application.get_env(:tds_cdc, :persistence, [])
      Application.put_env(:tds_cdc, :persistence, path: dir)

      on_exit(fn ->
        Application.put_env(:tds_cdc, :persistence, original)
      end)

      positions = %{"dbo_users" => <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>}
      :ok = FilePersistence.save_positions(:readable_test, positions)

      content = File.read!(Path.join(dir, "readable_test.json"))
      assert content =~ "0x00000001:00000000:0001"
    end
  end
end