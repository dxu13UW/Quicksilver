defmodule Quicksilver.Integrations.HTTP.MintAdapter do
  @moduledoc """
  Real HTTP transport on top of `Mint` (one connection per request).

  Our request volume is a handful per half hour, so connection reuse isn't worth
  the complexity. TLS always verifies the peer against OTP's system CA store
  (`:public_key.cacerts_get/0`); never turn that off. HTTP/1.1 only.

  Options: `:timeout` (ms, whole request including connect; default 30 s),
  `:max_body` (bytes, default 64 MiB; poe.ninja's `BaseType` overview is the
  largest response we know of).
  """

  @behaviour Quicksilver.Integrations.HTTP

  alias Quicksilver.Integrations.HTTP.Response

  @impl true
  def request(method, url, headers, body, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    max_body = Keyword.get(opts, :max_body, 64 * 1024 * 1024)
    deadline = now() + timeout
    uri = URI.parse(url)

    with {:ok, scheme} <- scheme(uri),
         {:ok, conn} <-
           Mint.HTTP.connect(scheme, uri.host, uri.port,
             mode: :passive,
             protocols: [:http1],
             transport_opts: transport_opts(scheme, timeout)
           ) do
      try do
        case Mint.HTTP.request(conn, method, path(uri), headers, body) do
          {:ok, conn, ref} ->
            recv(conn, ref, deadline, max_body, %{status: nil, headers: [], body: [], size: 0})

          {:error, _conn, reason} ->
            {:error, {:transport, reason}}
        end
      after
        Mint.HTTP.close(conn)
      end
    else
      {:error, %{reason: reason}} -> {:error, {:transport, reason}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp scheme(%URI{scheme: "https", host: h}) when is_binary(h), do: {:ok, :https}
  defp scheme(%URI{scheme: "http", host: h}) when is_binary(h), do: {:ok, :http}
  defp scheme(uri), do: {:error, {:bad_url, URI.to_string(uri)}}

  defp transport_opts(:https, timeout),
    do: [timeout: timeout, verify: :verify_peer, cacerts: :public_key.cacerts_get()]

  defp transport_opts(:http, timeout), do: [timeout: timeout]

  defp path(%URI{path: p, query: q}) do
    p = if p in [nil, ""], do: "/", else: p
    if q, do: p <> "?" <> q, else: p
  end

  defp recv(conn, ref, deadline, max_body, acc) do
    remaining = deadline - now()

    if remaining <= 0 do
      {:error, {:transport, :timeout}}
    else
      case Mint.HTTP.recv(conn, 0, remaining) do
        {:ok, conn, responses} ->
          handle(responses, conn, ref, deadline, max_body, acc)

        {:error, _conn, %{reason: :timeout}, _} ->
          {:error, {:transport, :timeout}}

        {:error, _conn, reason, _} ->
          {:error, {:transport, reason}}
      end
    end
  end

  defp handle([], conn, ref, deadline, max_body, acc),
    do: recv(conn, ref, deadline, max_body, acc)

  defp handle([{:status, ref, s} | rest], conn, ref, d, m, acc),
    do: handle(rest, conn, ref, d, m, %{acc | status: s})

  defp handle([{:headers, ref, h} | rest], conn, ref, d, m, acc) do
    h = Enum.map(h, fn {k, v} -> {String.downcase(k), v} end)
    handle(rest, conn, ref, d, m, %{acc | headers: acc.headers ++ h})
  end

  defp handle([{:data, ref, data} | rest], conn, ref, d, m, acc) do
    size = acc.size + byte_size(data)

    if size > m,
      do: {:error, {:transport, :body_too_large}},
      else: handle(rest, conn, ref, d, m, %{acc | body: [acc.body | data], size: size})
  end

  defp handle([{:done, ref} | _], _conn, ref, _d, _m, acc) do
    {:ok,
     %Response{status: acc.status, headers: acc.headers, body: IO.iodata_to_binary(acc.body)}}
  end

  defp handle([{:error, ref, reason} | _], _conn, ref, _d, _m, _acc),
    do: {:error, {:transport, reason}}

  defp handle([_other | rest], conn, ref, d, m, acc), do: handle(rest, conn, ref, d, m, acc)

  defp now, do: System.monotonic_time(:millisecond)
end
