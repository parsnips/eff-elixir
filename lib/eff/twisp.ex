defmodule Eff.Twisp do
  @moduledoc """
  Docker container management for the Twisp local image.
  """

  @image "public.ecr.aws/twisp/local:latest"
  @healthcheck_timeout_ms 120_000
  @healthcheck_interval_ms 2_000

  @doc """
  Starts a Twisp container or connects to an existing endpoint.

  If `TWISP_ENDPOINT` is set (e.g. "http://localhost:8080"), skips container
  startup and returns a handle pointing at that endpoint.

  Otherwise pulls the Docker image, starts a container with a random host port
  mapped to 8080, and waits for the healthcheck to pass.
  """
  def start(opts \\ []) do
    case System.get_env("TWISP_ENDPOINT") do
      nil ->
        start_container(opts)

      "" ->
        start_container(opts)

      endpoint ->
        graphql_endpoint = String.trim_trailing(endpoint, "/") <> "/financial/v1/graphql"
        {:ok, %{graphql_endpoint: graphql_endpoint, container_id: nil}}
    end
  end

  @doc """
  Stops and removes the Docker container. No-op if container_id is nil.
  """
  def cleanup(%{container_id: nil}), do: :ok

  def cleanup(%{container_id: container_id}) do
    System.cmd("docker", ["stop", container_id], stderr_to_stdout: true)
    System.cmd("docker", ["rm", "-f", container_id], stderr_to_stdout: true)
    :ok
  end

  defp start_container(_opts) do
    with :ok <- pull_image(),
         {:ok, container_id} <- run_container(),
         {:ok, port} <- get_mapped_port(container_id),
         :ok <- wait_for_healthcheck("http://localhost:#{port}", @healthcheck_timeout_ms) do
      graphql_endpoint = "http://localhost:#{port}/financial/v1/graphql"
      {:ok, %{graphql_endpoint: graphql_endpoint, container_id: container_id}}
    end
  end

  defp pull_image do
    case System.cmd("docker", ["pull", @image], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, "docker pull failed (exit #{code}): #{output}"}
    end
  end

  defp run_container do
    args = [
      "run",
      "-d",
      "-p",
      "0:8080",
      @image
    ]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {container_id, 0} -> {:ok, String.trim(container_id)}
      {output, code} -> {:error, "docker run failed (exit #{code}): #{output}"}
    end
  end

  defp get_mapped_port(container_id) do
    case System.cmd("docker", ["port", container_id, "8080"], stderr_to_stdout: true) do
      {output, 0} ->
        # Output is like "0.0.0.0:55000\n" or "0.0.0.0:55000\n:::55000\n"
        port =
          output
          |> String.trim()
          |> String.split("\n")
          |> List.first()
          |> String.split(":")
          |> List.last()

        {:ok, port}

      {output, code} ->
        {:error, "docker port failed (exit #{code}): #{output}"}
    end
  end

  defp wait_for_healthcheck(base_url, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_healthcheck(base_url <> "/healthcheck", deadline)
  end

  defp do_healthcheck(url, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, "healthcheck timed out after #{@healthcheck_timeout_ms}ms"}
    else
      case Req.get(url, retry: false, connect_options: [timeout: 5_000], receive_timeout: 5_000) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        _ ->
          Process.sleep(@healthcheck_interval_ms)
          do_healthcheck(url, deadline)
      end
    end
  end
end
