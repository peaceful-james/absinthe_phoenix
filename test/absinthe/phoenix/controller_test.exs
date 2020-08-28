defmodule Absinthe.Phoenix.ControllerTest do
  use ExUnit.Case, async: true
  use Absinthe.Phoenix.ConnCase
  use Absinthe.Phoenix.ChannelCase

  setup_all do
    Absinthe.Test.prime(Schema)

    children = [
      {Phoenix.PubSub, [name: Absinthe.Phoenix.PubSub, adapter: Phoenix.PubSub.PG2]},
      Absinthe.Phoenix.TestEndpoint,
      {Absinthe.Subscription, Absinthe.Phoenix.TestEndpoint}
    ]

    {:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)
    :ok
  end

  defmodule Schema do
    use Absinthe.Schema

    object :mutation_result do
      field :echo, :integer
    end

    query do
      field :string, :string do
        arg :echo, :string
        resolve &resolve_echo/3
      end

      field :integer, :integer do
        arg :echo, :integer
        resolve &resolve_echo/3
      end

      field :list_of_integers, list_of(:integer) do
        arg :echo, list_of(:integer)
        resolve &resolve_echo/3
      end

      field :input_object_with_integers, :deep_integers do
        arg :echo, :deep_integers_input
        resolve &resolve_echo/3
      end
    end

    mutation do
      field :update_integer, :mutation_result do
        arg :echo, :integer
        resolve &resolve_update_integer/3
      end
    end

    subscription do
      field :updated_integer, :mutation_result do
        config(fn _, _ -> {:ok, topic: "*"} end)
        trigger(:update_integer, topic: fn _ -> ["*"] end)
        resolve(fn %{integer: integer}, _, _ -> {:ok, %{echo: integer}} end)
      end
    end

    object :deep_integers do
      field :foo, :integer
      field :bar, :integer
      field :baz, :integer
    end

    input_object :deep_integers_input do
      field :foo, :integer
      field :bar, :integer
      field :baz, :integer
    end

    def resolve_echo(_, %{echo: echo}, _) do
      {:ok, echo}
    end

    def resolve_update_integer(_, %{echo: echo}, _) do
      {:ok, %{echo: echo}}
    end
  end

  defmodule ReverseSchema do
    use Absinthe.Schema

    query do
      field :string, :string do
        arg :echo, :string
        resolve &resolve_echo/3
      end
    end

    def resolve_echo(_, %{echo: echo}, _) do
      {:ok, echo |> String.reverse()}
    end
  end

  defmodule Controller do
    use Phoenix.Controller

    use Absinthe.Phoenix.Controller,
      schema: Absinthe.Phoenix.ControllerTest.Schema,
      action: [mode: :internal]

    @graphql """
    query ($echo: String) { string(echo: $echo) }
    """
    def string(conn, %{data: data}), do: json(conn, data)

    @graphql {"""
              query ($echo: String) { string(echo: $echo) }
              """, ReverseSchema}
    def reverse_string(conn, %{data: data}), do: json(conn, data)

    @graphql """
    query ($echo: Int) { integer(echo: $echo) }
    """
    def integer(conn, %{data: data}), do: json(conn, data)

    @graphql """
    query ($echo: [Int]) { list_of_integers(echo: $echo) }
    """
    def list_of_integers(conn, %{data: data}), do: json(conn, data)

    @graphql """
    query ($echo: DeepIntegersInput) { input_object_with_integers(echo: $echo) }
    """
    def input_object_with_integers(conn, %{data: data}), do: json(conn, data)

    @graphql """
    mutation UpdateInteger($echo: Int) {
    update_integer(echo: $echo){
    echo
    }
    }
    """
    def update_integer(conn, %{data: data}), do: json(conn, data)

  end

  describe "input" do
    test "string" do
      assert %{"string" => "one"} == result(Controller, :string, %{"echo" => "one"})
    end

    test "integer" do
      assert %{"integer" => 1} == result(Controller, :integer, %{"echo" => "1"})
    end

    test "list of integers" do
      assert %{"list_of_integers" => [1, 2, 3]} ==
               result(Controller, :list_of_integers, %{"echo" => ~w(1 2 3)})
    end

    test "input object with integers" do
      assert %{"input_object_with_integers" => %{"foo" => 1, "bar" => 2, "baz" => 3}} ==
               result(Controller, :input_object_with_integers, %{
                 "echo" => %{"foo" => "1", "bar" => "2", "baz" => "3"}
               })
    end

    test "trigger subscription via controller mutation" do

      {:ok, _, socket} =
        socket(Absinthe.Phoenix.TestSocket, nil, absinthe: %{schema: Schema, opts: []})
        |> subscribe_and_join(Absinthe.Phoenix.Channel, "__absinthe__:control")

      ref =
        Phoenix.ChannelTest.push(socket, "doc", %{
              "query" => "subscription {updatedInteger { echo }}"
                                 })

      assert_reply(ref, :ok, %{subscriptionId: subscription_ref})

      assert %{"update_integer" => %{"echo" => 1}} ==
        result(Controller, :update_integer, %{"echo" => "1"})

      assert_push("subscription:data", push)
    end
  end

  describe "using an alternate schema" do
    test "can be defined using a @graphql tuple" do
      assert %{"string" => "eno"} == result(Controller, :reverse_string, %{"echo" => "one"})
    end
  end

  def result(controller, name, params, verb \\ :get) do
    conn = build_conn(verb, "/", params) |> Plug.Conn.fetch_query_params()

    controller.call(conn, controller.init(name))
    |> json_response(200)
  end
end
