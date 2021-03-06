defmodule ExWebsocketSkeleton.Wsserv do
  use GenServer
  alias ExWebsocketSkeleton.Wsserv.Handler
  alias ExWebsocketSkeleton.Wsserv.Supervisor
  require Bitwise
  require Logger
  require Record

  @doc """
   0                   1                   2                   3
   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  +-+-+-+-+-------+-+-------------+-------------------------------+
  |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
  |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
  |N|V|V|V|       |S|             |   (if payload len==126/127)   |
  | |1|2|3|       |K|             |                               |
  +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
  |     Extended payload length continued, if payload len == 127  |
  + - - - - - - - - - - - - - - - +-------------------------------+
  |                               |Masking-key, if MASK set to 1  |
  +-------------------------------+-------------------------------+
  | Masking-key (continued)       |          Payload Data         |
  +-------------------------------- - - - - - - - - - - - - - - - +
  :                     Payload Data continued ...                :
  + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
  |                     Payload Data continued ...                |
  +---------------------------------------------------------------+
  """

  @tag Atom.to_string(__MODULE__)

  @websocket_prefix        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-Websocket-Accept: "
  @websocket_append_to_key "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @fin_on  0b1
  @fin_off 0b0

  @rsv_on  0b1
  @rsv_off 0b0

  @opcode_continue 0x0
  @opcode_text     0x1
  @opcode_bin      0x2
  @opcode_close    0x8
  @opcode_ping     0x9
  @opcode_pong     0xA

  @mask_on  0b1
  @mask_off 0b0

  @payload_length_normal    125
  @payload_length_extend_16 126
  @payload_length_extend_64 127
  @max_unsigned_integer_16  65532
  @max_unsigned_integer_64  9223372036854775807

  Record.defrecord :dataframe,
    fin:     @fin_off,
    rsv1:    @rsv_off, rsv2: @rsv_off, rsv3: @rsv_off,
    opcode:  @opcode_text,
    mask:    @mask_off,
    pllen:   0x0,
    maskkey: 0x0,
    data:    nil,
    msg:     nil

  Record.defrecord :servstat,
    lsock:     nil,
    csock:     nil,
    dataframe: nil,
    hdlpid:    nil,
    body:      nil

  #################
  # API Functions #
  #################

  def start_link(lsock, body) do
    GenServer.start_link(__MODULE__, [lsock, body])
  end

  def send_text(wsservpid, data) do
    GenServer.cast(wsservpid, {:send, @opcode_text, data})
  end

  def send_close(wsservpid) do
    GenServer.cast(wsservpid, {:send, @opcode_close, ""})
  end

  def send_pong(wsservpid) do
    GenServer.cast(wsservpid, {:send, @opcode_pong, ""})
  end

  #######################
  # GenServer Callbacks #
  #######################

  @doc """
  """
  def init([lsock, body]) do
    Logger.metadata tag: @tag
    Logger.debug "Wsserv start"
    {:ok, hdlpid} = Handler.start_link(self, body)
    Process.flag :trap_exit, true
    GenServer.cast self, :accept
    {:ok, servstat(lsock: lsock, hdlpid: hdlpid, body: body)}
  end

  @doc """
  """
  def handle_info({:tcp, _, msg}, state = servstat(csock: csock)) do
    dataframe = decode_dataframe(msg)
    :io.format("dataframe: ~p~n", [dataframe])
    IO.puts dataframe(dataframe, :data)
    :inet.setopts(servstat(state, :csock), [active: :once])
    data = dataframe(dataframe, :data)
    hdlpid = servstat(state, :hdlpid)
    case dataframe(dataframe, :opcode) do
      @opcode_text ->
        Handler.notify_text(hdlpid, data)
        {:noreply, servstat(state, dataframe: dataframe)}
      @opcode_bin ->
        Handler.notify_bin(hdlpid, data)
        {:noreply, servstat(state, dataframe: dataframe)}
      @opcode_ping ->
        Logger.debug "found ping dataframe"
        send_pong(self)
        {:noreply, servstat(state, dataframe: dataframe)}
      @opcode_continue ->
        Logger.debug "found continue dataframe"
        # not implemented
        {:noreply, servstat(state, dataframe: dataframe)}
      @opcode_close ->
        :gen_tcp.close(csock)
        Handler.notify_close(hdlpid)
        {:stop, :close_request, state}
    end
  end

  @doc """
  """
  def handle_info({:tcp_closed, _}, state) do
    Logger.error "tcp connection closed"
    {:stop, :normal, state}
  end

  @doc """
  """
  def handle_info({:tcp_error, _, _}, state) do
    Logger.error "an error on tcp connection"
    {:stop, :normal, state}
  end

  @doc """
  """
  def handle_info(_, state) do
    Logger.error "unknown error on tcp connection"
    {:noreply, state}
  end

  @doc """
  """
  def handle_cast(:accept, state = servstat(lsock: lsock)) do
    Logger.debug "waiting for connection"
    {:ok, csock} = :gen_tcp.accept(lsock)
    case do_handshake(csock, HashDict.new) do
      {:ok, _} ->
        Logger.info "handshake passed"
        :inet.setopts(csock, [packet: :raw, active: :once])
        Supervisor.start_wsserv
        {:noreply, servstat(state, csock: csock)}
      {:stop, reason, _} -> {:stop, reason, state}
      _ -> {:stop, "failed handshake with unknown reason", state}
    end
  end

  def handle_cast({:send, opcode, data}, state = servstat(csock: csock)) do
    Logger.debug "send message to client"
    packet = encode_dataframe(data, %{opcode: opcode})
    case opcode do
      @opcode_text ->
        :gen_tcp.send(csock, packet)
        {:noreply, state}
      @opcode_close ->
        :gen_tcp.send(csock, packet)
        {:stop, :close_request, state}
      @opcode_pong ->
        :gen_tcp.send(csock, packet)
        {:noreply, state}
    end
  end


  ####################
  # Module functions #
  ####################

  defp do_handshake(csock, headers) do
    case :gen_tcp.recv(csock, 0) do
      {:ok, {:http_request, _, {:abs_path, path}, _}} -> do_handshake(csock, Dict.put(headers, :path, path))
      {:ok, {:http_header, _, httpField, _, value}} ->
        hkey = {:http_field, httpField}
        do_handshake(csock, Dict.put(headers, hkey, value))
      {:error, "\r\n"} -> do_handshake(csock, headers)
      {:error, "\n"} -> do_handshake(csock, headers)
      {:ok, :http_eoh} ->
        verify_handshake(csock, headers)
        {:ok, [{:headers, headers}]}
      others ->
        Logger.info "unknown msg"
        {:stop, :unknown_header, [headers: headers, msg: others]}
    end
  end

  defp verify_handshake(csock, headers) do
    :io.format("headers: ~p~n", [headers])
    try do
      "websocket" = Dict.get(headers, {:http_field, :'Upgrade'}, '') |> List.to_string |> String.downcase()
      "upgrade" = Dict.get(headers, {:http_field, :'Connection'}, '') |> List.to_string |> String.downcase()
      "13" = Dict.get(headers, {:http_field, 'Sec-Websocket-Version'}, '') |> List.to_string()
      true = Dict.has_key?(headers, {:http_field, 'Sec-Websocket-Key'})
      send_handshake(csock, headers)
    catch
      _ -> Logger.error "an error during verification handshake"
    end
  end

  defp send_handshake(csock, headers) do
    swkey = Dict.get(headers, {:http_field, 'Sec-Websocket-Key'}, '') |> List.to_string()
    acceptHeader = swkey |> make_accept_header_value
                         |> (fn(acceptHeaderValue) -> @websocket_prefix <> acceptHeaderValue <> "\r\n\r\n" end).()
    :gen_tcp.send(csock, acceptHeader)
  end

  defp make_accept_header_value(swkey) do
    swkey <> @websocket_append_to_key |> (fn(k) -> :crypto.hash(:sha, k) end).() |> :base64.encode_to_string() |> List.to_string()
  end

  defp encode_dataframe(data, %{opcode: opcode, mask: mask}) do
    finRsvOpcode = Bitwise.bor(0b10000000, opcode)
    {maskkey, newData} = apply_mask({mask, data})
    _encode_dataframe(finRsvOpcode, maskkey, newData, 0b10000000)
  end

  defp encode_dataframe(data, %{opcode: opcode}) do
    finRsvOpcode = Bitwise.bor(0b10000000, opcode)
    _encode_dataframe(finRsvOpcode, nil, data, 0b00000000)
  end

  defp _encode_dataframe(finRsvOpcode, nil, data, maskOnOffBits) do
    dataSize = byte_size(data)
    cond do
      dataSize <= @payload_length_normal ->
        maskPayloadLength = Bitwise.bor(maskOnOffBits, dataSize)
        <<finRsvOpcode, maskPayloadLength, data :: binary>>
      @payload_length_normal < dataSize and dataSize <= @payload_length_extend_16 ->
        maskPayloadLength = Bitwise.bor(maskOnOffBits, @payload_length_extend_16)
        <<finRsvOpcode, maskPayloadLength, data :: binary>>
      @payload_length_extend_16 < dataSize and dataSize <= @payload_length_extend_64 ->
        maskPayloadLength = Bitwise.bor(maskOnOffBits, @payload_length_extend_64)
        <<finRsvOpcode, maskPayloadLength, data :: binary>>
      true ->
        raise "not found proper payload length"
    end
  end

  defp _encode_dataframe(finRsvOpcode, maskkey, data, maskOnOffBits) do
    dataSize = byte_size(data)
    cond do
      dataSize <= @payload_length_normal ->
        maskPayloadLength = Bitwise.bor(maskOnOffBits, dataSize)
        <<finRsvOpcode, maskPayloadLength, maskkey :: size(16), data :: binary>>
      @payload_length_normal < dataSize and dataSize <= @payload_length_extend_16 ->
        maskPayloadLength = Bitwise.bor(maskOnOffBits, @payload_length_extend_16)
        <<finRsvOpcode, maskPayloadLength, maskkey :: size(16), data :: binary>>
      @payload_length_extend_16 < dataSize and dataSize <= @payload_length_extend_64 ->
        maskPayloadLength = Bitwise.bor(maskOnOffBits, @payload_length_extend_64)
        <<finRsvOpcode, maskPayloadLength, maskkey :: size(16), data :: binary>>
      true ->
        raise "not found proper payload length"
    end
  end

  defp decode_dataframe(rawmsg) do
    <<fin :: size(1),
      rsv1 :: size(1),
      rsv2 :: size(1),
      rsv3 :: size(1),
      opcode :: size(4),
      mask :: size(1),
      payloadLen :: size(7),
      remainmsg :: binary>> = rawmsg
    cond do
      payloadLen <= @payload_length_normal and mask === @mask_on ->
        Logger.debug "payload: normal & mask: on"
        {maskkey, data} = remainmsg |> extract_mask_key() |> apply_mask()
        dataframe(fin: fin,
                  rsv1: rsv1,
                  rsv2: rsv2,
                  rsv3: rsv3,
                  opcode: opcode,
                  mask: mask,
                  maskkey: maskkey,
                  pllen: payloadLen,
                  data: data,
                  msg: rawmsg)
      payloadLen <= @payload_length_normal and mask === @mask_off ->
        Logger.debug "payload: normal & mask: off"
        dataframe(fin: fin,
                  rsv1: rsv1,
                  rsv2: rsv2,
                  rsv3: rsv3,
                  opcode: opcode,
                  mask: mask,
                  maskkey: nil,
                  pllen: payloadLen,
                  data: remainmsg,
                  msg: rawmsg)
      payloadLen === @payload_length_extend_16 and mask === @mask_on ->
        Logger.debug "payload: extend 16 & mask: on"
        {payloadLen16, remainmsg2} = extract_extend_payload_length_16(remainmsg)
        {maskkey, data} = remainmsg2 |> extract_mask_key() |> apply_mask()
        dataframe(fin: fin,
                  rsv1: rsv1,
                  rsv2: rsv2,
                  rsv3: rsv3,
                  opcode: opcode,
                  mask: mask,
                  maskkey: maskkey,
                  pllen: payloadLen16,
                  data: data,
                  msg: rawmsg)
      payloadLen === @payload_length_extend_16 and mask === @mask_off ->
        Logger.debug "payload: extend 16 & mask: off"
        {payloadLen16, remainmsg2} = extract_extend_payload_length_16(remainmsg)
        dataframe(fin: fin,
                  rsv1: rsv1,
                  rsv2: rsv2,
                  rsv3: rsv3,
                  opcode: opcode,
                  mask: mask,
                  maskkey: nil,
                  pllen: payloadLen16,
                  data: remainmsg2,
                  msg: rawmsg)
      payloadLen === @payload_length_extend_64 and mask === @mask_on ->
        Logger.debug "payload: extend 64 & mask: on"
        {payloadLen64, remainmsg2} = extract_extend_payload_length_64(remainmsg)
        {maskkey, data} = remainmsg2 |> extract_mask_key() |> apply_mask()
        dataframe(fin: fin,
                  rsv1: rsv1,
                  rsv2: rsv2,
                  rsv3: rsv3,
                  opcode: opcode,
                  mask: mask,
                  maskkey: maskkey,
                  pllen: payloadLen64,
                  data: data,
                  msg: rawmsg)
      payloadLen === @payload_length_extend_64 and mask === @mask_off ->
        Logger.debug "payload: extend 64 & mask: off"
        {payloadLen64, remainmsg2} = extract_extend_payload_length_16(remainmsg)
        dataframe(fin: fin,
                  rsv1: rsv1,
                  rsv2: rsv2,
                  rsv3: rsv3,
                  opcode: opcode,
                  mask: mask,
                  maskkey: nil,
                  pllen: payloadLen64,
                  data: remainmsg2,
                  msg: rawmsg)
      true -> raise "unknown payload length"
    end
  end

  defp extract_mask_key(rawmsg) do
    <<maskkey :: binary - size(4),
      remainmsg :: binary>> = rawmsg
    {maskkey, remainmsg}
  end

  defp extract_extend_payload_length_16(rawmsg) do
    <<len :: unsigned - integer - size(16),
      remainmsg :: binary>> = rawmsg
    {len, remainmsg}
  end

  defp extract_extend_payload_length_64(rawmsg) do
    <<len :: unsigned - integer - size(64),
      remainmsg :: binary>> = rawmsg
    {len, remainmsg}
  end

  defp apply_mask({maskkey, remainmsg}) do
    :io.format("maskkey: ~p~n", [maskkey])
    :io.format("remainmsg: ~p~n", [remainmsg])
    msgsize = byte_size(remainmsg)
    msgsizetrun = trunc(msgsize / 4)
    msgsizerem = rem(msgsize, 4)
    <<msk1 :: size(8),
      msk2 :: size(8),
      msk3 :: size(8),
      msk4 :: size(8)>> = maskkey
    lastMaskkeyList = case msgsizerem do
                        1 -> [msk1]
                        2 -> [msk1, msk2]
                        3 -> [msk1, msk2, msk3]
                        _ -> []
                      end
    maskkeyList = ([msk1, msk2, msk3, msk4] |> List.duplicate(msgsizetrun)
                                            |> List.flatten()) ++ lastMaskkeyList
    remainmsgList = :binary.bin_to_list(remainmsg)
    IO.inspect({:remainmsgList, remainmsgList})
    IO.inspect({:maskkeyList, maskkeyList})
    valmaskeds = for {val, mask} <- List.zip([remainmsgList, maskkeyList]), do: Bitwise.bxor(val, mask)
    maskedremainmsg = valmaskeds |> :binary.list_to_bin()
    {maskkey, maskedremainmsg}
  end

end
