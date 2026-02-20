defmodule Eff.GraphQL do
  @moduledoc """
  HTTP GraphQL client with retry and exponential backoff.
  """

  @max_retries 5
  @base_delay_ms 200

  @doc """
  Creates a new GraphQL client map.
  """
  def new_client(endpoint, headers \\ %{}) do
    %{endpoint: endpoint, headers: headers}
  end

  @doc """
  Executes a GraphQL operation. Returns `{:ok, data}` or `{:error, reason}`.
  """
  def execute(client, query, variables \\ %{}) do
    body = Jason.encode!(%{query: query, variables: variables})
    do_execute(client, body, 0)
  end

  @doc """
  Like `execute/3` but raises on error.
  """
  def execute!(client, query, variables \\ %{}) do
    case execute(client, query, variables) do
      {:ok, data} -> data
      {:error, reason} -> raise "GraphQL request failed: #{inspect(reason)}"
    end
  end

  defp do_execute(client, body, attempt) when attempt >= @max_retries do
    case do_post(client, body) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_execute(client, body, attempt) do
    case do_post(client, body) do
      {:ok, data} ->
        {:ok, data}

      {:error, %Req.TransportError{reason: reason}}
      when reason in [:econnrefused, :econnreset, :closed, :timeout] ->
        delay = @base_delay_ms * Bitwise.bsl(1, attempt)
        Process.sleep(delay)
        do_execute(client, body, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_post(client, body) do
    headers =
      Map.merge(
        %{"content-type" => "application/json"},
        client.headers
      )

    case Req.post(client.endpoint,
           body: body,
           headers: headers,
           retry: false,
           connect_options: [timeout: 30_000],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"data" => _data, "errors" => errors}}} when is_list(errors) ->
        {:error, {:graphql_errors, errors}}

      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, data}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
