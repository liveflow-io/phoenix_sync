defmodule Phoenix.Sync.Electric.ClientAdapterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Phoenix.Sync.Electric.ClientAdapter
  alias Phoenix.Sync.PredefinedShape

  defmodule MockFetch do
    def validate_opts(opts), do: {:ok, opts}

    def fetch(request, parent: parent) do
      send(parent, {:fetch_request, request})

      %Electric.Client.Fetch.Response{
        status: 200,
        headers: %{},
        body: ["[]"]
      }
    end
  end

  test "forwards request headers to sync server" do
    {:ok, client} =
      Electric.Client.new(
        base_url: "elixir://#{inspect(__MODULE__.Fetch)}",
        fetch: {MockFetch, parent: self()}
      )

    adapter = %ClientAdapter{client: client}

    conn =
      conn(:get, "/v1/shapes", %{})
      |> Plug.Conn.put_req_header("my-header-1", "my-header-1-value-1")
      |> Plug.Conn.prepend_req_headers([{"my-header-1", "my-header-1-value-2"}])
      |> Plug.Conn.put_req_header("my-header-2", "my-header-2-value")

    assert %{status: 200} = Phoenix.Sync.Adapter.PlugApi.call(adapter, conn, %{offset: -1})
    assert_receive {:fetch_request, request}

    assert request.headers == [
             {"my-header-1", "my-header-1-value-1"},
             {"my-header-1", "my-header-1-value-2"},
             {"my-header-2", "my-header-2-value"}
           ]
  end

  test "for predefined shapes forwards non-shape params and blocks overrides" do
    {:ok, client} =
      Electric.Client.new(
        base_url: "elixir://#{inspect(__MODULE__.Fetch)}",
        params: %{secret: "server-secret", source_id: "server-source-id", extra: "server-extra"},
        fetch: {MockFetch, parent: self()}
      )

    predefined_shape = PredefinedShape.new!("todos", [])

    adapter = %ClientAdapter{
      client: PredefinedShape.client(client, predefined_shape),
      shape_definition: predefined_shape
    }

    conn = conn(:get, "/v1/shapes", %{})

    params = %{
      "offset" => "-1",
      "handle" => "my-shape-handle",
      "live" => "true",
      "cursor" => "my-next-cursor",
      "live_sse" => "true",
      "experimental_live_sse" => "true",
      "expired_handle" => "expired-shape-handle",
      "log" => "debug",
      "cache-buster" => "cache-buster-value",
      "custom_param" => "custom-value",
      "table" => "ignored-table-query-param",
      "where" => "ignored-where-query-param",
      "replica" => "ignored-replica-query-param",
      "params" => "ignored-params-query-param",
      "secret" => "client-secret-should-not-override",
      "source_id" => "client-source-id-should-not-override",
      "extra" => "client-extra-should-not-override",
      "subset__where" => ~s|"user_id" = $1|,
      "subset__limit" => "50",
      "subset__offset" => "10",
      "subset__order_by" => "inserted_at desc",
      "subset__params" => %{"1" => "123"},
      "subset__where_expr" => "some where expr",
      "subset__order_by_expr" => "some order by expr"
    }

    assert %{status: 200} = Phoenix.Sync.Adapter.PlugApi.call(adapter, conn, params)
    assert_receive {:fetch_request, request}

    assert request.offset == "-1"
    assert request.shape_handle == "my-shape-handle"
    assert request.live == true
    assert request.next_cursor == "my-next-cursor"

    request_params = stringify_keys(request.params)

    # shape params are defined server-side, client params are protected from
    # request overrides, and non-shape params are passed through.
    assert request_params["table"] == "todos"
    assert request_params["secret"] == "server-secret"
    assert request_params["source_id"] == "server-source-id"
    assert request_params["extra"] == "server-extra"
    assert request_params["live_sse"] == "true"
    assert request_params["experimental_live_sse"] == "true"
    assert request_params["expired_handle"] == "expired-shape-handle"
    assert request_params["log"] == "debug"
    assert request_params["cache-buster"] == "cache-buster-value"
    assert request_params["custom_param"] == "custom-value"
    assert request_params["subset__where"] == ~s|"user_id" = $1|
    assert request_params["subset__limit"] == "50"
    assert request_params["subset__offset"] == "10"
    assert request_params["subset__order_by"] == "inserted_at desc"
    assert request_params["subset__params"] == %{"1" => "123"}
    assert request_params["subset__where_expr"] == "some where expr"
    assert request_params["subset__order_by_expr"] == "some order by expr"

    refute Map.has_key?(request_params, "where")
    refute Map.has_key?(request_params, "replica")
    refute Map.has_key?(request_params, "params")
  end

  defp stringify_keys(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end
end
