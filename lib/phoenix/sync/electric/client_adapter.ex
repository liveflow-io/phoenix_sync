defmodule Phoenix.Sync.Electric.ClientAdapter do
  @moduledoc false

  defstruct [:client, :shape_definition]

  defimpl Phoenix.Sync.Adapter.PlugApi do
    alias Electric.Client
    alias Electric.Client.Fetch

    alias Phoenix.Sync.PredefinedShape

    # Predefined-shape routes must not allow overriding server-defined shape
    # attributes or stream-position keys (which are passed via dedicated fields).
    @blocked_passthrough_keys ~w(
      table
      where
      columns
      params
      replica
      where_expr
      order_by_expr
      order_by
      limit
      offset
      handle
      live
      cursor
    )

    @json Phoenix.Sync.json_library()
    @subset_body_keys ~w(where order_by limit offset params where_expr order_by_expr)

    def predefined_shape(sync_client, %PredefinedShape{} = predefined_shape) do
      shape_client = PredefinedShape.client(sync_client.client, predefined_shape)

      {:ok,
       %Phoenix.Sync.Electric.ClientAdapter{
         client: shape_client,
         shape_definition: predefined_shape
       }}
    end

    def call(sync_client, conn, params) do
      {request, shape} = request(sync_client, conn, params)

      fetch_upstream(sync_client, conn, request, shape)
    end

    def response(sync_client, %{method: method} = conn, params) when method in ["GET", "POST"] do
      {request, shape} = request(sync_client, conn, params)

      make_request(sync_client, conn, request, shape)
    end

    def send_response(_sync_client, conn, response) do
      conn
      |> put_resp_headers(response.headers)
      |> Plug.Conn.send_resp(response.status, response.body)
    end

    # this is the server-defined shape route, so we want to only pass on the
    # per-request/stream position params and protocol-level params, leaving
    # the shape-definition params from the configured client.
    defp request(%{shape_definition: %PredefinedShape{} = shape} = sync_client, conn, params) do
      request_params = request_query_params(conn, params)

      {
        Client.request(
          sync_client.client,
          stream_request_attrs(conn.method, request_params,
            params: protocol_request_params(sync_client, request_params)
          )
        ),
        shape
      }
    end

    # this version is the pure client-defined shape version
    defp request(sync_client, %{method: method} = conn, params) do
      request_params = request_query_params(conn, params)

      {
        Client.request(
          sync_client.client,
          stream_request_attrs(method, request_params,
            params:
              Map.drop(request_params, [
                "offset",
                :offset,
                "handle",
                :handle,
                "live",
                :live,
                "cursor",
                :cursor
              ])
          )
        ),
        nil
      }
    end

    defp normalise_method(method), do: method |> String.downcase() |> String.to_atom()
    defp live?(live), do: live == "true"

    defp protocol_request_params(%{client: %{params: client_params}}, params) do
      client_param_keys =
        client_params
        |> stringify_keys()
        |> Map.keys()

      params
      |> stringify_keys()
      |> Map.drop(@blocked_passthrough_keys ++ client_param_keys)
    end

    defp stringify_keys(params) do
      Map.new(params, fn {key, value} -> {to_string(key), value} end)
    end

    defp stream_request_attrs(method, params, attrs) do
      [
        method: normalise_method(method),
        offset: param(params, "offset"),
        shape_handle: param(params, "handle"),
        live: live?(param(params, "live")),
        next_cursor: param(params, "cursor")
      ]
      |> Keyword.merge(attrs)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    end

    defp param(params, key) do
      Map.get(params, key) || Map.get(params, String.to_existing_atom(key))
    rescue
      ArgumentError -> Map.get(params, key)
    end

    defp request_query_params(conn, fallback_params) do
      query_params = map_or_empty(conn.query_params)
      path_params = map_or_empty(conn.path_params)
      body_params = map_or_empty(conn.body_params)

      cond do
        map_size(query_params) > 0 or map_size(path_params) > 0 ->
          Map.merge(query_params, path_params)

        conn.method == "POST" and map_size(body_params) > 0 ->
          %{}

        true ->
          fallback_params
      end
    end

    defp fetch_upstream(sync_client, conn, request, shape) do
      response = make_request(sync_client, conn, request, shape)

      send_response(sync_client, conn, response)
    end

    defp make_request(sync_client, conn, request, shape) do
      request = put_req_headers(request, conn.req_headers)
      post_body = post_subset_body(conn)

      response =
        case request_upstream(sync_client.client, request, post_body) do
          %Client.Fetch.Response{} = response -> response
          {:error, %Client.Fetch.Response{} = response} -> response
        end

      body =
        if response.status == 200 do
          Phoenix.Sync.Electric.map_response_body(
            response.body,
            PredefinedShape.transform_fun(shape)
          )
        else
          response.body
        end

      %{response | body: body}
    end

    defp request_upstream(client, request, post_body) do
      if Map.get(request, :method) == :post and map_size(post_body) > 0 do
        case client.fetch do
          {Electric.Client.Fetch.HTTP, fetch_opts} when is_list(fetch_opts) ->
            http_post_request(client, request, post_body, fetch_opts)

          _ ->
            request
            |> Map.put(:body, post_body)
            |> then(&Client.Fetch.request(client, &1))
        end
      else
        Client.Fetch.request(client, request)
      end
    end

    defp http_post_request(client, request, post_body, fetch_opts) do
      now = DateTime.utc_now()

      authenticated_request =
        request
        |> Map.update!(:headers, &Map.new/1)
        |> then(&apply(Client, :authenticate_request, [client, &1]))

      req =
        apply(Electric.Client.Fetch.HTTP, :build_request, [authenticated_request, fetch_opts])
        |> Req.Request.delete_header("content-length")
        |> Req.Request.put_header("content-type", "application/json")
        |> Map.put(:body, @json.encode_to_iodata!(post_body))

      case Req.request(req) do
        {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
          Fetch.Response.decode!(status, headers, body, now)

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp post_subset_body(%{method: "POST"} = conn) do
      conn.body_params
      |> map_or_empty()
      |> normalize_post_subset_body()
    end

    defp post_subset_body(_conn), do: %{}

    defp normalize_post_subset_body(%{} = body_params) do
      existing_subset =
        body_params
        |> Map.take(["subset", :subset])
        |> Map.values()
        |> Enum.filter(&is_map/1)
        |> Enum.reduce(%{}, &Map.merge(&2, &1))

      top_level_subset =
        body_params
        |> Enum.filter(fn {key, _value} -> subset_body_key?(key) end)
        |> Map.new(fn {key, value} -> {to_string(key), value} end)

      Map.merge(existing_subset, top_level_subset)
    end

    defp subset_body_key?(key) when is_binary(key), do: key in @subset_body_keys

    defp subset_body_key?(key) when is_atom(key),
      do: key |> Atom.to_string() |> subset_body_key?()

    defp subset_body_key?(_key), do: false

    defp put_req_headers(request, headers) do
      merged_headers =
        Enum.reduce(headers, request.headers, fn {header, value}, acc ->
          Map.update(acc, header, [value], fn existing -> [value | List.wrap(existing)] end)
        end)
        |> expand_headers()

      %{request | headers: merged_headers}
    end

    defp put_resp_headers(conn, headers) do
      resp_headers =
        headers
        |> Map.delete("transfer-encoding")
        |> expand_headers()

      Plug.Conn.merge_resp_headers(conn, resp_headers)
    end

    # turn headers into a list which is more compatible than a map
    # representation as it preserves multiple values for a header.
    defp expand_headers(headers) when is_map(headers) do
      Enum.flat_map(headers, fn {k, v} -> Enum.map(List.wrap(v), &{k, &1}) end)
    end

    defp map_or_empty(%Plug.Conn.Unfetched{}), do: %{}
    defp map_or_empty(map) when is_map(map), do: map
    defp map_or_empty(_), do: %{}
  end
end
