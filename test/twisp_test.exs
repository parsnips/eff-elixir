defmodule TwispTest do
  use ExUnit.Case

  alias Eff.{GraphQL, Operations, Twisp}

  @moduletag timeout: 300_000

  setup_all do
    {:ok, _} = GraphQL.start_pool()
    {:ok, twisp} = Twisp.start()

    on_exit(fn -> Twisp.cleanup(twisp) end)

    %{twisp: twisp}
  end

  defp new_client(twisp) do
    GraphQL.new_client(
      twisp.graphql_endpoint,
      %{"x-twisp-account-id" => UUID.uuid4()},
      finch: GraphQL.Finch
    )
  end

  defp run_scenario(twisp) do
    client = new_client(twisp)

    # 1. Create activity index
    {:ok, activity_resp} = Operations.create_activity_index(client)
    assert get_in(activity_resp, ["schema", "createIndex", "on"]) == "Entry"

    # 2. Setup journal, tran code, accounts
    {:ok, setup_resp} =
      Operations.setup(
        client,
        Eff.journal_id(),
        Eff.tran_code_id(),
        Eff.account1_id(),
        Eff.account2_id()
      )

    assert get_in(setup_resp, ["createJournal", "journalId"]) == Eff.journal_id()
    assert get_in(setup_resp, ["createTranCode", "tranCodeId"]) == Eff.tran_code_id()
    assert get_in(setup_resp, ["ernie_checking", "accountId"]) == Eff.account1_id()
    assert get_in(setup_resp, ["bert_checking", "accountId"]) == Eff.account2_id()

    # 3. Post 4 transactions
    dates = ["2026-01-01", "2026-01-15", "2026-01-31", "2026-02-15"]

    {close_stamp, _} =
      dates
      |> Enum.with_index()
      |> Enum.reduce({nil, nil}, fn {effective, idx}, {close_stamp, _} ->
        tx_id = UUID.uuid4()
        {:ok, resp} = Operations.post_transaction(client, tx_id, effective)
        assert get_in(resp, ["postTransaction", "transactionId"]) == tx_id

        # Capture created timestamp from the Jan 31 transaction (index 2)
        if idx == 2 do
          created = get_in(resp, ["postTransaction", "created"])
          {created, nil}
        else
          {close_stamp, nil}
        end
      end)

    # 4. Compute jan_close_stamp_str = created + 1ms
    jan_close_stamp_str = add_millisecond(close_stamp)

    # 5. Post backdated adjustment: effective Jan 24, statement date Feb 15
    tx_id = UUID.uuid4()
    {:ok, backdated_resp} =
      Operations.post_transaction_with_statement_date(client, tx_id, "2026-01-24", "2026-02-15")
    assert get_in(backdated_resp, ["postTransaction", "transactionId"]) == tx_id

    # 6. Query January statement balance
    {:ok, jan_balance} =
      Operations.statement_balance(
        client,
        Eff.account1_id(),
        Eff.journal_id(),
        "2025-12-31",
        "2026-01-31",
        jan_close_stamp_str,
        jan_close_stamp_str
      )

    assert get_in(jan_balance, ["open", "available", "normalBalance", "units"]) == "0.00"
    assert get_in(jan_balance, ["closed", "available", "normalBalance", "units"]) == "3.00"

    # 7. Query February statement balance
    feb_close_stamp =
      DateTime.utc_now()
      |> DateTime.add(3600, :second)
      |> DateTime.to_iso8601()

    {:ok, feb_balance} =
      Operations.statement_balance(
        client,
        Eff.account1_id(),
        Eff.journal_id(),
        "2026-01-31",
        "2026-02-28",
        jan_close_stamp_str,
        feb_close_stamp
      )

    assert get_in(feb_balance, ["open", "available", "normalBalance", "units"]) == "3.00"
    assert get_in(feb_balance, ["closed", "available", "normalBalance", "units"]) == "9.00"

    # 8. Query activity index — January
    {:ok, jan_activity} =
      Operations.activity_query(client, Eff.journal_id(), Eff.account1_id(), "2026-01")

    jan_nodes = get_in(jan_activity, ["entries", "nodes"])
    assert length(jan_nodes) == 3

    assert Enum.map(jan_nodes, fn n -> get_in(n, ["metadata", "effective"]) end) ==
             ["2026-01-31", "2026-01-15", "2026-01-01"]

    assert Enum.map(jan_nodes, fn n -> get_in(n, ["metadata", "statementDate"]) end) ==
             ["2026-01-31", "2026-01-15", "2026-01-01"]

    assert Enum.all?(jan_nodes, fn n -> get_in(n, ["amount", "units"]) == "1.00" end)

    for node <- jan_nodes do
      codes =
        get_in(node, ["transaction", "entries", "nodes"])
        |> Enum.map(fn e -> get_in(e, ["account", "code"]) end)

      assert "ERNIE.CHECKING" in codes
      assert "BERT.CHECKING" in codes
    end

    # 9. Query activity index — February
    {:ok, feb_activity} =
      Operations.activity_query(client, Eff.journal_id(), Eff.account1_id(), "2026-02")

    feb_nodes = get_in(feb_activity, ["entries", "nodes"])
    assert length(feb_nodes) == 2

    [backdated_entry, regular_entry] = feb_nodes

    assert get_in(backdated_entry, ["metadata", "effective"]) == "2026-01-24"
    assert get_in(backdated_entry, ["metadata", "statementDate"]) == "2026-02-15"
    assert get_in(backdated_entry, ["amount", "units"]) == "5.00"

    assert get_in(regular_entry, ["metadata", "effective"]) == "2026-02-15"
    assert get_in(regular_entry, ["metadata", "statementDate"]) == "2026-02-15"
    assert get_in(regular_entry, ["amount", "units"]) == "1.00"

    for node <- feb_nodes do
      codes =
        get_in(node, ["transaction", "entries", "nodes"])
        |> Enum.map(fn e -> get_in(e, ["account", "code"]) end)

      assert "ERNIE.CHECKING" in codes
      assert "BERT.CHECKING" in codes
    end

    :ok
  end

  test "point-in-time effective and statement dates", %{twisp: twisp} do
    assert :ok == run_scenario(twisp)
  end

  test "parallel runs", %{twisp: twisp} do
    num_runs =
      case System.get_env("RUNS") do
        nil -> 10
        "" -> 10
        n -> String.to_integer(n)
      end

    tasks =
      for _i <- 1..num_runs do
        Task.async(fn -> run_scenario(twisp) end)
      end

    results = Task.await_many(tasks, 300_000)
    assert Enum.all?(results, &(&1 == :ok))
  end

  # Parses an RFC3339 timestamp string, adds 1 millisecond, and returns the
  # updated string. Handles both nanosecond and microsecond precision.
  defp add_millisecond(timestamp_str) do
    # The timestamp from Twisp may have nanosecond precision like:
    # "2026-01-31T12:00:00.123456789Z"
    # Elixir's DateTime only handles microsecond precision, so we parse carefully.
    case DateTime.from_iso8601(timestamp_str) do
      {:ok, dt, _offset} ->
        dt
        |> DateTime.add(1, :millisecond)
        |> format_nanosecond_timestamp()

      {:error, _} ->
        # If standard parsing fails, try manual nanosecond parsing
        add_millisecond_manual(timestamp_str)
    end
  end

  defp format_nanosecond_timestamp(dt) do
    # Format with microsecond precision (Elixir's max) then append "Z"
    Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S") <>
      format_fractional(dt.microsecond) <> "Z"
  end

  defp format_fractional({0, 0}), do: ""

  defp format_fractional({usec, precision}) do
    frac =
      usec
      |> Integer.to_string()
      |> String.pad_leading(6, "0")
      |> String.slice(0, precision)

    "." <> frac
  end

  # Fallback for nanosecond timestamps that Elixir can't natively parse.
  # Parses the fractional seconds as nanoseconds, adds 1_000_000 ns (1ms),
  # and reconstructs the string.
  defp add_millisecond_manual(timestamp_str) do
    regex = ~r/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.?(\d*)Z$/

    case Regex.run(regex, timestamp_str) do
      [_, datetime_part, frac_str] ->
        # Pad fractional to 9 digits (nanoseconds)
        frac_padded = String.pad_trailing(frac_str, 9, "0")
        nanos = String.to_integer(frac_padded)
        new_nanos = nanos + 1_000_000

        if new_nanos >= 1_000_000_000 do
          # Overflow into seconds — parse datetime part, add 1 second, then set remaining nanos
          {:ok, dt, _} = DateTime.from_iso8601(datetime_part <> "Z")
          dt = DateTime.add(dt, 1, :second)
          remaining = new_nanos - 1_000_000_000
          new_frac = remaining |> Integer.to_string() |> String.pad_leading(9, "0")
          Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S") <> "." <> new_frac <> "Z"
        else
          new_frac = new_nanos |> Integer.to_string() |> String.pad_leading(9, "0")
          datetime_part <> "." <> new_frac <> "Z"
        end

      _ ->
        # No fractional seconds at all
        {:ok, dt, _} = DateTime.from_iso8601(timestamp_str)
        dt = DateTime.add(dt, 1, :millisecond)
        DateTime.to_iso8601(dt)
    end
  end
end
