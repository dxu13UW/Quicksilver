defmodule Quicksilver.Integrations.FixtureHTTP do
  @moduledoc """
  Test HTTP adapter that replays recorded responses from
  `test/fixtures/integrations/*.json`. It never touches the network: a URL
  without a route returns `{:error, {:no_fixture, url}}`.

      http = FixtureHTTP.start(%{
        Urls.trade_leagues() => {:fixture, "trade_leagues"},
        url2 => [{:error, :econnrefused}, {:fixture, "x", status: 503}]
      })
      # pass `adapter: http` to HTTP.get_json/2 (or `http: [adapter: http, ...]` to a server)

  A route is one response spec or a list consumed in order (the last one
  repeats). Specs:

    * `{:fixture, name}` / `{:fixture, name, overrides}`: a recorded file;
      overrides are `status:`, `headers:` (replace same-named headers),
      `body:` (a JSON term, or a fun applied to the recorded body).
    * `%HTTP.Response{}` or `{:error, reason}`.
    * `{:gate, pid, spec}`: sends `{:fixture_gate, request_pid, url}` to `pid`
      and waits for `:open` before answering with `spec`.

  `requests/1` returns `[{method, url, headers}]` in call order.
  """

  @behaviour Quicksilver.Integrations.HTTP

  alias Quicksilver.Integrations.HTTP.Response

  @dir Path.expand("../../fixtures/integrations", __DIR__)

  @doc "Starts the route table (linked to the caller). Returns an adapter for `HTTP.get_json/2`."
  def start(routes) do
    {:ok, agent} = Agent.start_link(fn -> %{routes: routes, requests: []} end)
    {__MODULE__, agent: agent}
  end

  @doc "Requests made so far, oldest first."
  def requests({__MODULE__, agent: agent}), do: Agent.get(agent, &Enum.reverse(&1.requests))

  @doc "Replaces or adds routes."
  def put_routes({__MODULE__, agent: agent}, routes),
    do: Agent.update(agent, fn s -> %{s | routes: Map.merge(s.routes, routes)} end)

  @doc "Loads a fixture file as `{status, headers, body_term}`."
  def load(name) do
    fx = Path.join(@dir, name <> ".json") |> File.read!() |> Jason.decode!()
    {fx["status"], Enum.map(fx["headers"], fn [k, v] -> {k, v} end), fx["body"]}
  end

  @impl true
  def request(method, url, headers, _body, opts) do
    agent = Keyword.fetch!(opts, :agent)

    spec =
      Agent.get_and_update(agent, fn s ->
        s = %{s | requests: [{method, url, headers} | s.requests]}

        case Map.get(s.routes, url) do
          nil -> {nil, s}
          [only] -> {only, s}
          [next | rest] -> {next, put_in(s.routes[url], rest)}
          [] -> {nil, s}
          spec -> {spec, s}
        end
      end)

    respond(spec, url)
  end

  defp respond(nil, url), do: {:error, {:no_fixture, url}}
  defp respond({:error, _} = e, _url), do: e
  defp respond(%Response{} = r, _url), do: {:ok, r}

  defp respond({:gate, pid, spec}, url) do
    send(pid, {:fixture_gate, self(), url})

    receive do
      :open -> respond(spec, url)
    after
      10_000 -> {:error, :gate_timeout}
    end
  end

  defp respond({:fixture, name}, url), do: respond({:fixture, name, []}, url)

  defp respond({:fixture, name, overrides}, _url) do
    {status, headers, body} = load(name)

    body =
      case Keyword.fetch(overrides, :body) do
        {:ok, f} when is_function(f, 1) -> f.(body)
        {:ok, b} -> b
        :error -> body
      end

    extra = Keyword.get(overrides, :headers, [])
    names = Enum.map(extra, &elem(&1, 0))
    headers = Enum.reject(headers, fn {k, _} -> k in names end) ++ extra

    {:ok,
     %Response{
       status: Keyword.get(overrides, :status, status),
       headers: headers,
       body: Jason.encode!(body)
     }}
  end
end
