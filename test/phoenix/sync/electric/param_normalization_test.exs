defmodule Phoenix.Sync.Electric.ParamNormalizationTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Phoenix.Sync.Electric

  describe "normalize_subset_params/1" do
    test "nests binary subset__ params under subset" do
      params = %{
        "offset" => "-1",
        "subset__where" => ~s|completed = $1|,
        "subset__params" => %{"1" => "false"}
      }

      assert Electric.normalize_subset_params(params) == %{
               "offset" => "-1",
               "subset" => %{
                 "where" => ~s|completed = $1|,
                 "params" => %{"1" => "false"}
               }
             }
    end

    test "nests atom subset__ params under subset" do
      params = %{
        offset: "-1",
        subset__where: ~s|completed = $1|,
        subset__params: %{"1" => "false"}
      }

      assert Electric.normalize_subset_params(params) == %{
               :offset => "-1",
               "subset" => %{
                 "where" => ~s|completed = $1|,
                 "params" => %{"1" => "false"}
               }
             }
    end

    test "merges into an existing subset map" do
      params = %{
        "offset" => "-1",
        "subset" => %{"limit" => "20"},
        :subset => %{"order_by" => "id"},
        "subset__where" => ~s|completed = $1|
      }

      assert Electric.normalize_subset_params(params) == %{
               "offset" => "-1",
               "subset" => %{
                 "limit" => "20",
                 "order_by" => "id",
                 "where" => ~s|completed = $1|
               }
             }
    end

    test "POST nests plain subset body keys under subset" do
      params = %{
        "offset" => "-1",
        "handle" => "h1",
        "where" => ~s|completed = $1|,
        "params" => %{"1" => "false"},
        "limit" => 10
      }

      assert Electric.normalize_subset_params(params, "POST") == %{
               "offset" => "-1",
               "handle" => "h1",
               "subset" => %{
                 "where" => ~s|completed = $1|,
                 "params" => %{"1" => "false"},
                 "limit" => 10
               }
             }
    end

    test "POST conn-based normalization mirrors HTTP merge semantics" do
      conn = %{
        conn(:post, "/v1/shape?offset=0_0&handle=h1", "{}")
        | query_params: %{
            "offset" => "0_0",
            "handle" => "h1",
            "subset__where" => ~s|id = $1|
          },
          body_params: %{
            "params" => %{"1" => "123"},
            "limit" => 5
          },
          path_params: %{}
      }

      # Simulate merged params that could have conflicting keys.
      merged_params = %{"offset" => "SHOULD_NOT_WIN", "where" => "also not used"}

      assert Electric.normalize_subset_params(conn, merged_params) == %{
               "offset" => "0_0",
               "handle" => "h1",
               "subset" => %{
                 "where" => ~s|id = $1|,
                 "params" => %{"1" => "123"},
                 "limit" => 5
               }
             }
    end

    test "POST keeps stream offset at root and subset offset nested" do
      conn = %{
        conn(:post, "/v1/shape?offset=10_5&handle=h1", "{}")
        | query_params: %{"offset" => "10_5", "handle" => "h1"},
          body_params: %{"offset" => 20, "where" => ~s|id > 10|},
          path_params: %{}
      }

      assert Electric.normalize_subset_params(conn, %{}) == %{
               "offset" => "10_5",
               "handle" => "h1",
               "subset" => %{"offset" => 20, "where" => ~s|id > 10|}
             }
    end

    test "GET keeps plain where and params at root" do
      params = %{
        "offset" => "-1",
        "table" => "todos",
        "where" => ~s|completed = $1|,
        "params" => %{"1" => "false"}
      }

      assert Electric.normalize_subset_params(params, "GET") == params
    end
  end
end
