if Phoenix.Sync.sandbox_enabled?() do
  defmodule Phoenix.Sync.Sandbox.Stack do
    @moduledoc false

    use Supervisor, restart: :transient

    alias Phoenix.Sync.Sandbox

    @json Phoenix.Sync.json_library()

    def child_spec(opts) do
      {:ok, stack_id} = Keyword.fetch(opts, :stack_id)
      {:ok, repo} = Keyword.fetch(opts, :repo)
      {:ok, owner} = Keyword.fetch(opts, :owner)

      %{
        id: {__MODULE__, stack_id},
        start: {__MODULE__, :start_link, [stack_id, repo, owner]},
        type: :supervisor,
        restart: :transient
      }
    end

    def name(stack_id) do
      Phoenix.Sync.Sandbox.name({__MODULE__, stack_id})
    end

    def start_link(stack_id, repo, owner) do
      Supervisor.start_link(__MODULE__, {stack_id, repo, owner}, name: name(stack_id))
    end

    alias Electric.ShapeCache.Storage
    alias Electric.Shapes.Consumer.Snapshotter

    def snapshot_query(
          task_parent,
          consumer,
          shape_handle,
          shape,
          %{storage: storage, stack_id: stack_id},
          sandbox_pool
        ) do
      Postgrex.transaction(
        sandbox_pool,
        fn conn ->
          xmin = 1000
          xmax = 1100

          send(task_parent, {:ready_to_stream, self(), System.monotonic_time(:millisecond)})

          GenServer.cast(consumer, {:pg_snapshot_known, shape_handle, {xmin, xmax, []}})

          # Enforce display settings *before* querying initial data to maintain consistent
          # formatting between snapshot and live log entries.
          Enum.each(Electric.Postgres.display_settings(), &Postgrex.query!(conn, &1, []))

          # xmin/xmax/xip_list are uint64, so we need to convert them to strings for JS not to mangle them
          finishing_control_message =
            @json.encode!(%{
              headers: %{
                control: "snapshot-end",
                xmin: to_string(xmin),
                xmax: to_string(xmax),
                xip_list: []
              }
            })

          stream =
            Snapshotter.stream_initial_data(
              task_parent,
              consumer,
              conn,
              stack_id,
              shape,
              shape_handle
            )
            |> Stream.concat([finishing_control_message])

          Storage.make_new_snapshot!(stream, storage)
        end,
        timeout: :infinity
      )
    end

    def config(stack_id, repo, owner \\ nil) do
      publication_manager_spec =
        {Sandbox.PublicationManager, stack_id: stack_id, owner: owner, repo: repo}

      # persistent_kv = Electric.PersistentKV.Memory.new!()
      inspector = {Sandbox.Inspector, stack_id}

      %{pid: pool} = Ecto.Adapter.lookup_meta(repo.get_dynamic_repo())

      registry = Electric.StackSupervisor.registry_name(stack_id)

      storage = {
        Electric.ShapeCache.InMemoryStorage,
        [stack_id: stack_id, table_base_name: :"#{stack_id}"]
      }

      [
        stack_id: stack_id,
        storage: storage,
        inspector: inspector,
        publication_manager: publication_manager_spec,
        chunk_bytes_threshold: 10_485_760,
        db_pool: pool,
        log_producer: Electric.Replication.ShapeLogCollector.name(stack_id),
        consumer_supervisor: Electric.Shapes.DynamicConsumerSupervisor.name(stack_id),
        registry: registry,
        max_shapes: nil
      ]
    end

    def init({stack_id, repo, owner}) do
      config = config(stack_id, repo, owner)
      shape_cache_spec = {Electric.ShapeCache, stack_id: stack_id}
      persistent_kv = Electric.PersistentKV.Memory.new!()

      storage = Storage.shared_opts(config[:storage])

      create_snapshot_fn = fn task_parent, consumer, shape_handle, shape, ctx ->
        snapshot_query(task_parent, consumer, shape_handle, shape, ctx, config[:db_pool])
      end

      children = [
        {Electric.ProcessRegistry, partitions: 1, stack_id: stack_id},
        {Registry, keys: :duplicate, name: config[:registry]},
        {Electric.StackConfig,
         stack_id: stack_id,
         seed_config: [
           inspector: config[:inspector],
           create_snapshot_fn: create_snapshot_fn
         ]},
        Storage.stack_child_spec(storage),
        {Electric.ShapeCache.ShapeStatusOwner, stack_id: stack_id, storage: storage},
        {Electric.StatusMonitor, stack_id: stack_id},
        {Sandbox.Inspector, stack_id: stack_id, repo: repo},
        {Sandbox.Producer, stack_id: stack_id},
        {DynamicSupervisor,
         name: Phoenix.Sync.Sandbox.Fetch.name(stack_id), strategy: :one_for_one},
        Supervisor.child_spec(
          {
            Electric.Shapes.Supervisor,
            stack_id: stack_id,
            consumer_supervisor: {Electric.Shapes.DynamicConsumerSupervisor, stack_id: stack_id},
            shape_cleaner:
              {Electric.ShapeCache.ShapeCleaner.CleanupTaskSupervisor, stack_id: stack_id},
            shape_cache: shape_cache_spec,
            publication_manager: config[:publication_manager],
            log_collector: {
              Electric.Replication.ShapeLogCollector,
              stack_id: stack_id, inspector: config[:inspector], persistent_kv: persistent_kv
            },
            schema_reconciler: {Phoenix.Sync.Sandbox.SchemaReconciler, stack_id},
            expiry_manager: {Phoenix.Sync.Sandbox.ExpiryManager, stack_id: stack_id}
          },
          restart: :temporary
        )
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end
end
