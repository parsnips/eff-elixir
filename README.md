# Eff

Integration test suite for [Twisp](https://twisp.com) ledger effective-date balances, statement balances, backdated adjustments, and activity index queries.

Spins up a Twisp container via Docker (or connects to an existing endpoint), creates a journal with accounts and transaction codes, posts transactions across multiple effective dates, and verifies point-in-time balance queries and activity index results.

## Prerequisites

- Elixir ~> 1.16
- Docker (for running Twisp locally)

## Setup

```bash
mix deps.get
```

## Running Tests

Start a test run (this will pull and start a Twisp Docker container automatically):

```bash
mix test
```

To connect to an already-running Twisp instance instead of starting a container:

```bash
TWISP_ENDPOINT=http://localhost:8080 mix test
```

To control the number of parallel scenario runs (default: 10):

```bash
RUNS=20 mix test
```

## Project Structure

- `lib/eff.ex` — Well-known UUIDs for test fixtures (journal, tran code, accounts)
- `lib/eff/graphql.ex` — GraphQL HTTP client with retry and exponential backoff
- `lib/eff/operations.ex` — GraphQL mutations and queries for the Twisp ledger
- `lib/eff/twisp.ex` — Docker container lifecycle management for Twisp
- `test/twisp_test.exs` — Integration tests exercising the full ledger scenario

## License

MIT
