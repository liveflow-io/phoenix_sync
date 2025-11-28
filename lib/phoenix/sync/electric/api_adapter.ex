if Code.ensure_loaded?(Electric.Shapes.Api) do
  defmodule Phoenix.Sync.Electric.ApiAdapter do
    @moduledoc false

    defstruct [:api, :shape]

    alias Phoenix.Sync.PredefinedShape
    alias Electric.Shapes

    def new(%Shapes.Api{} = api, %PredefinedShape{} = predefined_shape) do
      with {:ok, configured_api} <-
             Shapes.Api.predefined_shape(api, PredefinedShape.to_api_params(predefined_shape)) do
        {:ok, %__MODULE__{api: configured_api, shape: predefined_shape}}
      end
    end

    defimpl Phoenix.Sync.Adapter.PlugApi do
      alias Phoenix.Sync.Electric.ApiAdapter

      def predefined_shape(_api, %PredefinedShape{} = _shape) do
        raise ArgumentError,
          message: "#{inspect(__MODULE__)} does not support nested predefined shapes"
      end

      def call(%ApiAdapter{api: api, shape: shape}, %{method: "GET"} = conn, params) do
        if transform_fun = PredefinedShape.transform_fun(shape) do
          case Shapes.Api.validate(api, params) do
            {:ok, request} ->
              response = Shapes.Api.serve_shape_log(request)
              response = Map.update!(response, :body, &apply_transform(&1, transform_fun))

              conn
              |> content_type()
              |> Plug.Conn.assign(:request, request)
              |> Plug.Conn.assign(:response, response)
              |> Shapes.Api.Response.send(response)

            {:error, response} ->
              conn
              |> content_type()
              |> Shapes.Api.Response.send(response)
              |> Plug.Conn.halt()
          end
        else
          Phoenix.Sync.Adapter.PlugApi.call(api, conn, params)
        end
      end

      def call(%ApiAdapter{api: api}, conn, params) do
        Phoenix.Sync.Adapter.PlugApi.call(api, conn, params)
      end

      # only works if method is GET...
      def response(%ApiAdapter{api: api, shape: shape}, %{method: "GET"} = conn, params) do
        if transform_fun = PredefinedShape.transform_fun(shape) do
          case Shapes.Api.validate(api, params) do
            {:ok, request} ->
              response = Shapes.Api.serve_shape_log(request)
              response = Map.update!(response, :body, &apply_transform(&1, transform_fun))
              {request, response}

            {:error, response} ->
              {nil, response}
          end
        else
          Phoenix.Sync.Adapter.PlugApi.response(api, conn, params)
          |> then(fn {request, response} ->
            {request, Phoenix.Sync.Electric.consume_response_stream(response)}
          end)
        end
      end

      def send_response(%ApiAdapter{}, conn, {request, response}) do
        conn
        |> content_type()
        |> Plug.Conn.assign(:request, request)
        |> Plug.Conn.assign(:response, response)
        |> Shapes.Api.Response.send(response)
      end

      defp content_type(conn) do
        Plug.Conn.put_resp_content_type(conn, "application/json")
      end

      defp apply_transform(stream, transform_fun) do
        stream
        |> Enum.to_list()
        |> IO.iodata_to_binary()
        |> Phoenix.Sync.Electric.map_response_body(transform_fun)
      end
    end
  end

  defimpl Phoenix.Sync.Adapter.PlugApi, for: Electric.Shapes.Api do
    alias Electric.Shapes

    alias Phoenix.Sync.PredefinedShape
    alias Phoenix.Sync.Electric.ApiAdapter

    def predefined_shape(api, %PredefinedShape{} = shape) do
      ApiAdapter.new(api, shape)
    end

    def call(api, %{method: "GET"} = conn, params) do
      case Shapes.Api.validate(api, params) do
        {:ok, request} ->
          conn
          |> content_type()
          |> Plug.Conn.assign(:request, request)
          |> Shapes.Api.serve_shape_log(request)

        {:error, response} ->
          conn
          |> content_type()
          |> Shapes.Api.Response.send(response)
          |> Plug.Conn.halt()
      end
    end

    def call(api, %{method: "DELETE"} = conn, params) do
      case Shapes.Api.validate_for_delete(api, params) do
        {:ok, request} ->
          conn
          |> content_type()
          |> Plug.Conn.assign(:request, request)
          |> Shapes.Api.delete_shape(request)

        {:error, response} ->
          conn
          |> content_type()
          |> Shapes.Api.Response.send(response)
          |> Plug.Conn.halt()
      end
    end

    def call(_api, %{method: "OPTIONS"} = conn, _params) do
      Shapes.Api.options(conn)
    end

    def response(api, _conn, params) do
      case Shapes.Api.validate(api, params) do
        {:ok, request} ->
          {
            request,
            Shapes.Api.serve_shape_log(request) |> Phoenix.Sync.Electric.consume_response_stream()
          }

        {:error, response} ->
          {nil, response}
      end
    end

    def send_response(%ApiAdapter{}, conn, {request, response}) do
      conn
      |> content_type()
      |> Plug.Conn.assign(:request, request)
      |> Plug.Conn.assign(:response, response)
      |> Shapes.Api.Response.send(response)
    end

    defp content_type(conn) do
      Plug.Conn.put_resp_content_type(conn, "application/json")
    end
  end
end
