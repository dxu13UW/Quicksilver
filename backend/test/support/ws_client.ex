defmodule Quicksilver.Test.WSClient do
  @moduledoc """
  Minimal WebSocket client for tests (mint_web_socket, test-only dependency).

  Every frame the server sends is forwarded to the owner process as
  `{:ws, client_pid, frame}`, where `frame` is `{:text, binary}`,
  `{:close, code, reason}`, etc. When the TCP connection ends the owner gets
  `{:ws, client_pid, :tcp_closed}`.
  """

  use GenServer

  @spec connect(:inet.port_number(), String.t()) :: {:ok, pid()} | {:error, term()}
  def connect(port, path \\ "/ws") do
    GenServer.start(__MODULE__, {port, path, self()})
  end

  def send_text(client, text), do: GenServer.call(client, {:send, {:text, text}})
  def send_binary(client, data), do: GenServer.call(client, {:send, {:binary, data}})
  def send_json(client, map), do: send_text(client, Jason.encode!(map))

  def close(client) do
    if Process.alive?(client), do: GenServer.stop(client, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({port, path, owner}) do
    with {:ok, conn} <- Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, []),
         {:ok, conn, status, headers} <- await_upgrade(conn, ref, nil, []),
         {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, %{conn: conn, ref: ref, websocket: websocket, owner: owner}}
    else
      {:error, reason} -> {:stop, reason}
      {:error, _conn, reason} -> {:stop, reason}
    end
  end

  defp await_upgrade(conn, ref, status, headers) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {status, headers, done?} =
              Enum.reduce(responses, {status, headers, false}, fn
                {:status, ^ref, s}, {_, h, d} -> {s, h, d}
                {:headers, ^ref, h}, {s, _, d} -> {s, h, d}
                {:done, ^ref}, {s, h, _} -> {s, h, true}
                _, acc -> acc
              end)

            if done?,
              do: {:ok, conn, status, headers},
              else: await_upgrade(conn, ref, status, headers)

          {:error, conn, reason, _responses} ->
            {:error, conn, reason}

          :unknown ->
            await_upgrade(conn, ref, status, headers)
        end
    after
      2_000 -> {:error, :upgrade_timeout}
    end
  end

  @impl true
  def handle_call({:send, frame}, _from, state) do
    {:ok, websocket, data} = Mint.WebSocket.encode(state.websocket, frame)

    case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, conn} ->
        {:reply, :ok, %{state | conn: conn, websocket: websocket}}

      {:error, conn, reason} ->
        {:reply, {:error, reason}, %{state | conn: conn, websocket: websocket}}
    end
  end

  @impl true
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = Enum.reduce(responses, %{state | conn: conn}, &handle_response/2)
        {:noreply, state}

      {:error, conn, _reason, _responses} ->
        send(state.owner, {:ws, self(), :tcp_closed})
        {:stop, :normal, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref} = state) do
    {:ok, websocket, frames} = Mint.WebSocket.decode(state.websocket, data)
    Enum.each(frames, &send(state.owner, {:ws, self(), &1}))
    %{state | websocket: websocket}
  end

  defp handle_response(_other, state), do: state
end
