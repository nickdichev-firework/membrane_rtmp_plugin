defmodule Membrane.RTMP.Source do
  @moduledoc """
  Membrane Element for receiving an RTMP stream. Acts as a RTMP Server.

  When initializing, the source sends `t:socket_control_needed_t/0` notification,
  upon which it should be granted the control over the `socket` via `:gen_tcp.controlling_process/2`.

  The Source allows for providing custom validator module, that verifies some of the RTMP messages.
  The module has to implement the `Membrane.RTMP.MessageValidator` behaviour.
  If the validation fails, a `t:stream_validation_failed_t/0` notification is sent.

  This implementation is limited to only AAC and H264 streams.
  """
  use Membrane.Source

  require Membrane.Logger

  alias Membrane.RTMP.{Handshake, MessageHandler, MessageParser}

  def_output_pad :output,
    availability: :always,
    accepted_format: Membrane.RemoteStream,
    mode: :pull

  def_options socket: [
                spec: :gen_tcp.socket(),
                description: """
                Socket on which the source will be receiving the RTMP stream.
                The socket must be already connected to the RTMP client and be in non-active mode (`active` set to `false`).
                """
              ],
              validator: [
                spec: Membrane.RTMP.MessageValidator,
                description: """
                A Module implementing `Membrane.RTMP.MessageValidator` behaviour, used for validating the stream.
                """
              ]

  @typedoc """
  Notification sent when the RTMP Source element is initialized and it should be granted control over the socket using `:gen_tcp.controlling_process/2`.
  """
  @type socket_control_needed_t() :: {:socket_control_needed, :gen_tcp.socket(), pid()}

  @type validation_stage_t :: :publish | :release_stream | :set_data_frame

  @typedoc """
  Notification sent when the validator approves given validation stage..
  """
  @type stream_validation_success_t() ::
          {:stream_validation_success, validation_stage_t(), result :: any()}

  @typedoc """
  Notification sent when the validator denies incoming RTMP stream.
  """
  @type stream_validation_failed_t() ::
          {:stream_validation_failed, validation_stage_t(), reason :: any()}

  @impl true
  def handle_init(_ctx, %__MODULE__{} = opts) do
    state =
      opts
      |> Map.from_struct()
      |> Map.merge(%{
        actions: [],
        header_sent?: false,
        message_parser: MessageParser.init(Handshake.init_server()),
        receiver_pid: nil,
        socket_ready?: false,
        # how many times the Source tries to get control of the socket
        socket_retries: 3,
        # epoch required for performing a handshake with the pipeline
        epoch: 0
      })

    {[notify_parent: {:socket_control_needed, state.socket, self()}], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    target_pid = self()

    {:ok, receiver_process} =
      Task.start_link(fn ->
        receive_loop(state.socket, target_pid)
      end)

    send(self(), :start_receiving)

    stream_format = [
      stream_format:
        {:output, %Membrane.RemoteStream{content_format: Membrane.FLV, type: :bytestream}}
    ]

    {stream_format, %{state | receiver_pid: receiver_process}}
  end

  defp receive_loop(socket, target) do
    receive do
      {:tcp, _port, packet} ->
        send(target, {:tcp, socket, packet})

      {:tcp_closed, _port} ->
        send(target, {:tcp_closed, socket})

      :terminate ->
        exit(:normal)

      _message ->
        :noop
    end

    receive_loop(socket, target)
  end

  @impl true
  def handle_demand(_pad, _size, _unit, _ctx, state) when state.socket_ready? do
    :inet.setopts(state.socket, active: :once)
    {[], state}
  end

  @impl true
  def handle_demand(_pad, _size, _unit, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_terminate_request(_ctx, state) do
    send(state.receiver_pid, :terminate)
    {[terminate: :normal], %{state | receiver_pid: nil}}
  end

  @impl true
  def handle_info(:start_receiving, _ctx, %{socket_retries: 0} = state) do
    Membrane.Logger.warn("Failed to take control of the socket")
    {[], state}
  end

  def handle_info(:start_receiving, _ctx, %{socket_retries: retries} = state) do
    case :gen_tcp.controlling_process(state.socket, state.receiver_pid) do
      :ok ->
        :ok = :inet.setopts(state.socket, active: :once)
        {[], %{state | socket_ready?: true}}

      {:error, :not_owner} ->
        Process.send_after(self(), :start_receiving, 200)
        {[], %{state | socket_retries: retries - 1}}
    end
  end

  @impl true
  def handle_info({:tcp, socket, packet}, _ctx, %{socket: socket} = state) do
    {messages, message_parser} =
      MessageHandler.parse_packet_messages(packet, state.message_parser)

    state = MessageHandler.handle_client_messages(messages, state)

    {state.actions, %{state | actions: [], message_parser: message_parser}}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, _ctx, state) do
    {[end_of_stream: :output], state}
  end

  @impl true
  def handle_info(_message, _ctx, state) do
    {[], state}
  end
end
