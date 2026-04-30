# ExDNA Agent Guidelines

This repository is part of the Elixir Vibe organization.

ExDNA detects code duplication using Elixir AST analysis.

## Development

Use the project’s Mix aliases whenever possible.

```sh
mix deps.get
mix compile
mix test
mix format
```

Preferred full check:

```sh
mix ci
```

Current full CI alias includes:

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix dialyzer
mix test
mix ex_dna
```

## Guidelines

- Duplication detection should be AST-aware, not text-based.
- Avoid noisy findings that make the tool less useful for agents.
- Prefer actionable reports: where duplication is, why it matters, and what extraction might look like.
- Keep output formats stable for downstream tools.
- Credo integration is optional; do not make core analysis depend on Credo at runtime unless intentional.
- Do not publish, tag, or bump versions unless explicitly requested.
