defmodule Plug.Builder do
  alias Plug.Conn

  @moduledoc """
  Conveniences for building plugs.

  This module can be used into a module in order to build
  a plug stack:

      defmodule MyApp do
        use Plug.Builder

        plug :hello, upper: true

        def hello(conn, opts) do
          body = if opts[:upper], do: "WORLD", else: "world"
          send_resp(conn, 200, body)
        end
      end

  `Plug.Builder` will define a `init/1` function (which is overridable)
  and a `call/2` function with the compiled stack. By implementing the
  Plug API, `Plug.Builder` guarantees this module can be handed to a web
  server or used as part of another stack.

  Note this module also exports a `compile/1` function for those willing
  to collect and compile their plugs manually.

  ## Halting a Plug Stack

  A Plug Stack can be halted with `Plug.Conn.halt/1`. The Builder will prevent
  further plugs downstream from being invoked and return current connection.
  """

  @type plug :: module | atom

  @doc false
  defmacro __using__(_) do
    quote do
      @behaviour Plug

      def init(opts) do
        opts
      end

      def call(conn, opts) do
        plug_builder_call(conn, opts)
      end

      defoverridable [init: 1, call: 2]

      import Plug.Builder, only: [plug: 1, plug: 2]
      Module.register_attribute(__MODULE__, :plugs, accumulate: true)
      @before_compile Plug.Builder
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    plugs = Module.get_attribute(env.module, :plugs)
    {conn, body} = Plug.Builder.compile(plugs)
    quote do
      defp plug_builder_call(unquote(conn), _), do: unquote(body)
    end
  end

  @doc """
  A macro that stores a new plug.
  """
  defmacro plug(plug, opts \\ []) do
    quote do
      @plugs {unquote(plug), unquote(opts), true}
    end
  end

  @doc """
  Compiles a plug stack.

  It expects a reversed stack (with the last plug coming first)
  and returns a tuple containing the reference to the connection
  as first argument and the compiled quote stack.
  """
  @spec compile([{plug, Plug.opts}]) :: {Macro.t, Macro.t}
  def compile(stack) do
    conn = quote do: conn
    {conn, Enum.reduce(stack, conn, &quote_plug(init_plug(&1), &2))}
  end

  defp init_plug({plug, opts, guard}) do
    case Atom.to_char_list(plug) do
      'Elixir.' ++ _ ->
        init_module_plug(plug, opts, guard)
      _ ->
        init_fun_plug(plug, opts, guard)
    end
  end

  defp init_module_plug(plug, opts, guard) do
    opts = plug.init(opts)

    if function_exported?(plug, :call, 2) do
      {:call, plug, opts, guard}
    else
      raise ArgumentError, message: "#{inspect plug} plug must implement call/2"
    end
  end

  defp init_fun_plug(plug, opts, guard) do
    {:fun, plug, opts, guard}
  end

  defp quote_plug({:call, plug, opts, guard}, acc) do
    call = quote do: unquote(plug).call(conn, unquote(Macro.escape(opts)))

    quote do
      case unquote(compile_guard(call, guard)) do
        %Conn{halted: true} = conn -> conn
        %Conn{} = conn             -> unquote(acc)
        _ -> raise "expected #{unquote(inspect plug)}.call/2 to return a Plug.Conn"
      end
    end
  end

  defp quote_plug({:fun, plug, opts, guard}, acc) do
    call = quote do: unquote(plug)(conn, unquote(Macro.escape(opts)))

    quote do
      case unquote(compile_guard(call, guard)) do
        %Conn{halted: true} = conn -> conn
        %Conn{} = conn             -> unquote(acc)
        _ -> raise "expected #{unquote(plug)}/2 to return a Plug.Conn"
      end
    end
  end

  defp compile_guard(call, true) do
    call
  end

  defp compile_guard(call, guard) do
    quote do
      case true do
        true when unquote(guard) -> unquote(call)
        true -> conn
      end
    end
  end
end
