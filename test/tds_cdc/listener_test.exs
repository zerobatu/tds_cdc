defmodule TdsCdc.ListenerTest do
  use ExUnit.Case, async: false

  describe "using macro" do
    test "defines a module with the Listener behaviour" do
      defmodule TestListener do
        use TdsCdc.Listener
      end

      assert function_exported?(TestListener, :start_link, 1)
      assert function_exported?(TestListener, :child_spec, 1)
      assert function_exported?(TestListener, :on_init, 1)
      assert function_exported?(TestListener, :on_insert, 2)
      assert function_exported?(TestListener, :on_update, 2)
      assert function_exported?(TestListener, :on_delete, 2)
      assert function_exported?(TestListener, :on_gap, 4)
      assert function_exported?(TestListener, :on_terminate, 2)
    end

    test "default on_init returns empty map" do
      defmodule DefaultInitListener do
        use TdsCdc.Listener
      end

      assert DefaultInitListener.on_init([]) == {:ok, %{}}
    end

    test "default on_insert returns state unchanged" do
      defmodule DefaultInsertListener do
        use TdsCdc.Listener
      end

      change = %TdsCdc.Change{
        capture_instance: "dbo_users",
        operation: :insert,
        data: %{id: 1},
        lsn: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>,
        seqval: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 2>>
      }

      assert DefaultInsertListener.on_insert(change, :my_state) == {:ok, :my_state}
    end

    test "default on_update returns state unchanged" do
      defmodule DefaultUpdateListener do
        use TdsCdc.Listener
      end

      change = %TdsCdc.Change{
        capture_instance: "dbo_users",
        operation: :update,
        data: %{id: 1},
        lsn: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>,
        seqval: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 2>>
      }

      assert DefaultUpdateListener.on_update(change, :my_state) == {:ok, :my_state}
    end

    test "default on_delete returns state unchanged" do
      defmodule DefaultDeleteListener do
        use TdsCdc.Listener
      end

      change = %TdsCdc.Change{
        capture_instance: "dbo_users",
        operation: :delete,
        data: %{id: 1},
        lsn: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>,
        seqval: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 2>>
      }

      assert DefaultDeleteListener.on_delete(change, :my_state) == {:ok, :my_state}
    end

    test "default on_gap logs warning and returns state unchanged" do
      defmodule DefaultGapListener do
        use TdsCdc.Listener
      end

      old_lsn = <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>
      min_lsn = <<0, 0, 0, 2, 0, 0, 0, 0, 0, 1>>

      assert DefaultGapListener.on_gap("dbo_users", old_lsn, min_lsn, :my_state) == {:ok, :my_state}
    end
  end

  describe "custom implementations" do
    test "overrides on_init" do
      defmodule CustomInitListener do
        use TdsCdc.Listener

        @impl true
        def on_init(opts) do
          {:ok, %{env: Keyword.get(opts, :env, :test)}}
        end
      end

      assert CustomInitListener.on_init(env: :prod) == {:ok, %{env: :prod}}
      assert CustomInitListener.on_init([]) == {:ok, %{env: :test}}
    end

    test "overrides on_insert" do
      defmodule CustomInsertListener do
        use TdsCdc.Listener

        @impl true
        def on_insert(change, state) do
          {:ok, [change | state]}
        end
      end

      change = %TdsCdc.Change{
        capture_instance: "dbo_users",
        operation: :insert,
        data: %{id: 1, name: "Alice"},
        lsn: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>,
        seqval: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 2>>
      }

      assert CustomInsertListener.on_insert(change, []) == {:ok, [change]}
    end

    test "overrides on_update" do
      defmodule CustomUpdateListener do
        use TdsCdc.Listener

        @impl true
        def on_update(_change, state) do
          {:ok, Map.update(state, :updates, 1, &(&1 + 1))}
        end
      end

      change = %TdsCdc.Change{
        capture_instance: "dbo_users",
        operation: :update,
        data: %{id: 1},
        lsn: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>,
        seqval: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 2>>
      }

      assert CustomUpdateListener.on_update(change, %{}) == {:ok, %{updates: 1}}
    end

    test "overrides on_delete" do
      defmodule CustomDeleteListener do
        use TdsCdc.Listener

        @impl true
        def on_delete(change, state) do
          {:ok, Map.put(state, :last_deleted, change.data)}
        end
      end

      change = %TdsCdc.Change{
        capture_instance: "dbo_users",
        operation: :delete,
        data: %{id: 2, name: "Bob"},
        lsn: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>,
        seqval: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 2>>
      }

      assert CustomDeleteListener.on_delete(change, %{}) == {:ok, %{last_deleted: %{id: 2, name: "Bob"}}}
    end

    test "overrides on_gap" do
      defmodule CustomGapListener do
        use TdsCdc.Listener

        @impl true
        def on_gap(ci, old_lsn, min_lsn, state) do
          {:ok, Map.put(state, :last_gap, {ci, old_lsn, min_lsn})}
        end
      end

      old_lsn = <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>
      min_lsn = <<0, 0, 0, 2, 0, 0, 0, 0, 0, 1>>

      result = CustomGapListener.on_gap("dbo_users", old_lsn, min_lsn, %{})
      assert result == {:ok, %{last_gap: {"dbo_users", old_lsn, min_lsn}}}
    end

    test "can return {:stop, reason} from any callback" do
      defmodule StoppingListener do
        use TdsCdc.Listener

        @impl true
        def on_insert(_change, _state) do
          {:stop, :max_reached}
        end
      end

      change = %TdsCdc.Change{
        capture_instance: "dbo_users",
        operation: :insert,
        data: %{id: 1},
        lsn: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>,
        seqval: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 2>>
      }

      assert StoppingListener.on_insert(change, %{}) == {:stop, :max_reached}
    end
  end

  describe "__dispatch_change/3" do
    test "dispatches insert to on_insert" do
      defmodule DispatchInsertListener do
        use TdsCdc.Listener

        @impl true
        def on_insert(_change, state) do
          {:ok, Map.update(state, :inserts, 1, &(&1 + 1))}
        end
      end

      change = %TdsCdc.Change{
        capture_instance: "dbo_users",
        operation: :insert,
        data: %{id: 1},
        lsn: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>,
        seqval: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 2>>
      }

      state = %{user_state: %{}}

      assert {:noreply, %{user_state: %{inserts: 1}}} =
               TdsCdc.Listener.__dispatch_change(DispatchInsertListener, change, state)
    end

    test "dispatches update to on_update" do
      defmodule DispatchUpdateListener do
        use TdsCdc.Listener

        @impl true
        def on_update(_change, state) do
          {:ok, Map.update(state, :updates, 1, &(&1 + 1))}
        end
      end

      change = %TdsCdc.Change{
        capture_instance: "dbo_users",
        operation: :update,
        data: %{id: 1},
        lsn: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>,
        seqval: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 2>>
      }

      state = %{user_state: %{}}

      assert {:noreply, %{user_state: %{updates: 1}}} =
               TdsCdc.Listener.__dispatch_change(DispatchUpdateListener, change, state)
    end

    test "dispatches delete to on_delete" do
      defmodule DispatchDeleteListener do
        use TdsCdc.Listener

        @impl true
        def on_delete(_change, state) do
          {:ok, Map.update(state, :deletes, 1, &(&1 + 1))}
        end
      end

      change = %TdsCdc.Change{
        capture_instance: "dbo_users",
        operation: :delete,
        data: %{id: 1},
        lsn: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>,
        seqval: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 2>>
      }

      state = %{user_state: %{}}

      assert {:noreply, %{user_state: %{deletes: 1}}} =
               TdsCdc.Listener.__dispatch_change(DispatchDeleteListener, change, state)
    end

    test "dispatches gap to on_gap" do
      defmodule DispatchGapListener do
        use TdsCdc.Listener

        @impl true
        def on_gap(ci, old_lsn, min_lsn, state) do
          {:ok, Map.put(state, :gap, {ci, old_lsn, min_lsn})}
        end
      end

      old_lsn = <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>
      min_lsn = <<0, 0, 0, 2, 0, 0, 0, 0, 0, 1>>
      state = %{user_state: %{}}

      assert {:noreply, %{user_state: %{gap: {"dbo_users", old_lsn, min_lsn}}}} =
               TdsCdc.Listener.__dispatch_gap(DispatchGapListener, "dbo_users", old_lsn, min_lsn, state)
    end

    test "handles unknown operation gracefully" do
      defmodule UnknownOpListener do
        use TdsCdc.Listener
      end

      change = %TdsCdc.Change{
        capture_instance: "dbo_users",
        operation: :unknown,
        data: %{id: 1},
        lsn: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 1>>,
        seqval: <<0, 0, 0, 1, 0, 0, 0, 0, 0, 2>>
      }

      state = %{user_state: :some_state}

      assert {:noreply, %{user_state: :some_state}} =
               TdsCdc.Listener.__dispatch_change(UnknownOpListener, change, state)
    end
  end

  describe "child_spec" do
    test "returns correct child spec" do
      defmodule ChildSpecListener do
        use TdsCdc.Listener
      end

      spec = ChildSpecListener.child_spec(conn: [hostname: "localhost"], capture_instances: ["dbo_users"])

      assert spec.id == ChildSpecListener
      assert spec.type == :worker
      assert spec.start == {ChildSpecListener, :start_link, [[conn: [hostname: "localhost"], capture_instances: ["dbo_users"]]]}
    end
  end
end