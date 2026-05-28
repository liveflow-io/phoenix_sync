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

  test "normalizes POST subset body params without overwriting stream offset" do
    body = %{
      "where" => "id = $1",
      "params" => %{"1" => "00000000-0000-0000-0000-000000000001"},
      "offset" => 10
    }

    conn =
      :post
      |> conn("/v1/shape?offset=now&log=changes_only", Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.fetch_query_params()
      |> Phoenix.Sync.Electric.fetch_post_body_params()

    assert Phoenix.Sync.Electric.normalize_subset_params(conn, conn.params) == %{
             "offset" => "now",
             "log" => "changes_only",
             "subset" => body
           }
  end

  test "keeps existing GET subset__ query param support" do
    params = %{
      "offset" => "-1",
      "subset__where" => "id = $1",
      "subset__params" => Jason.encode!(%{"1" => "1"})
    }

    assert Phoenix.Sync.Electric.normalize_subset_params(params) == %{
             "offset" => "-1",
             "subset" => %{
               "where" => "id = $1",
               "params" => Jason.encode!(%{"1" => "1"})
             }
           }
  end

  test "predefined shapes forward POST subset requests with JSON body" do
    {:ok, client} =
      Electric.Client.new(
        base_url: "elixir://#{inspect(__MODULE__.Fetch)}",
        fetch: {MockFetch, parent: self()}
      )

    shape = PredefinedShape.new!(table: "todos")

    {:ok, adapter} =
      Phoenix.Sync.Adapter.PlugApi.predefined_shape(%ClientAdapter{client: client}, shape)

    body = %{
      "where" => "id = $1",
      "params" => %{"1" => "00000000-0000-0000-0000-000000000001"}
    }

    conn =
      :post
      |> conn("/sync/todos?offset=now&log=changes_only", Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.fetch_query_params()
      |> Phoenix.Sync.Electric.fetch_post_body_params()

    assert %{status: 200} = Phoenix.Sync.Adapter.PlugApi.call(adapter, conn, conn.params)
    assert_receive {:fetch_request, request}

    assert request.method == :post
    assert request.params["table"] == "todos"
    assert request.params["log"] == "changes_only"
    assert request.offset == "now"
    assert Map.fetch!(request, :body) == body
  end
end
