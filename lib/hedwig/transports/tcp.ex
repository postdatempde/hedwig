defmodule Hedwig.Transports.TCP do
  @moduledoc """
  XMPP Socket connection
  """

  use Hedwig.Transport

  alias Hedwig.Conn
  alias Hedwig.Stanza

  @type t :: %__MODULE__{
               transport: module,
               pid:       pid,
               socket:    port,
               parser:    term,
               ssl?:      boolean,
               compress?: boolean}

  defstruct transport: __MODULE__,
            pid:       nil,
            socket:    nil,
            parser:    nil,
            ssl?:      false,
            compress?: false

  @doc """
  Open a socket connection to the XMPP server.
  """
  def connect(conn) do
    {:ok, pid} = GenServer.start(__MODULE__, [conn, self])
    {:ok, GenServer.call(pid, :get_transport)}
  end

  @doc """
  Send data over the socket.
  """
  def send(%Conn{socket: socket, ssl?: false}, stanza) do
    :gen_tcp.send socket, Stanza.to_xml(stanza)
  end
  def send(%Conn{socket: socket, ssl?: true}, stanza) do
    :ssl.send socket, Stanza.to_xml(stanza)
  end

  @doc """
  Checks if the connection is alive.
  """
  def connected?(%Conn{socket: socket}) do
    Process.alive?(socket)
  end

  @doc """
  Upgrades the connection to TLS.
  """
  def upgrade_to_tls({%Conn{pid: pid} = conn, opts}) do
    GenServer.call(pid, {:upgrade_to_tls, []})
    conn = get_transport(conn)
    Conn.start_stream({conn, opts})
  end

  def use_zlib(%Conn{} = conn) do
    conn
  end

  def get_transport(%Conn{pid: pid}) do
    GenServer.call(pid, :get_transport)
  end

  def reset_parser(%Conn{pid: pid}) do
    GenServer.cast(pid, :reset_parser)
  end

  def init([opts, conn]) do
    host = String.to_char_list(opts[:server])
    port = opts[:port]
    {:ok, socket} = :gen_tcp.connect(host, port, [:binary, active: :once])
    {:ok, parser} = :exml_stream.new_parser
    {:ok, %TCP{pid: conn, socket: socket, parser: parser}}
  end

  def handle_call(:get_transport, _from, state) do
    {:reply, transport(state), state}
  end

  def handle_call({:upgrade_to_tls, opts}, _from, state) do
    opts = Keyword.merge([reuse_sessions: true, verify: :verify_none], opts)
    {:ok, socket} = :ssl.connect(state.socket, opts)
    {:ok, parser} = :exml_stream.new_parser
    {:reply, socket, %TCP{state | socket: socket, parser: parser, ssl?: true}}
  end

  def handle_cast(:reset_parser, %TCP{parser: parser} = state) do
    {:ok, parser} = :exml_stream.reset_parser(parser)
    {:noreply, %TCP{state | parser: parser}}
  end

  def handle_info({:tcp, socket, data}, state) do
    :inet.setopts(socket, active: :once)
    handle_data(socket, data, state)
  end
  def handle_info({:ssl, socket, data}, state) do
    :ssl.setopts(socket, active: :once)
    handle_data(socket, data, state)
  end
  def handle_info({:tcp_closed, _socket}, state) do
    {:stop, :normal, state}
  end
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp handle_data(_socket, data, state) do
    {:ok, parser, stanzas} = :exml_stream.parse(state.parser, data)
    new_state = %TCP{state | parser: parser}
    for stanza <- stanzas do
      # TODO: send an event to a handler
      Kernel.send(state.pid, {:stanza, transport(new_state), stanza})
    end
    {:noreply, new_state}
  end

  defp transport(%TCP{} = state) do
    %Conn{
      transport: __MODULE__,
      pid:       self,
      socket:    state.socket,
      ssl?:      state.ssl?,
      compress?: state.compress?
    }
  end
end