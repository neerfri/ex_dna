# Changelog

## Unreleased

### Detection improvements

- **Characteristic vectors + LSH for Type-III detection** — Each fragment now
  carries a structural fingerprint vector (node-type frequency map). For large
  codebases (>200 candidates), Locality-Sensitive Hashing prunes the comparison
  space from O(n²) to near O(n), with cosine similarity pre-filtering before
  expensive tree edit distance verification.
- **Sibling window fingerprinting** — Consecutive statements in module bodies
  are fingerprinted as sliding windows (2–6 siblings). Catches clones where
  adjacent `def`s are copied between modules but surrounding code differs —
  previously invisible because the full block hash wouldn't match.
- **Cross-arity delegation grouping** — `def foo(x), do: foo(x, [])` followed
  by `def foo(x, opts)` are now grouped as a single unit for fingerprinting.
  Enables detection of duplicated wrapper+body patterns across modules.
- **Struct/map field order normalization** — `%User{name: x, age: y}` and
  `%User{age: y, name: x}` now produce the same hash in abstract mode (Type-II).

### Bug fixes

- **`has_dsl_call?` logic error** — The macro suggestion detector was resetting
  its `found` flag on non-DSL nodes, losing detection when a DSL call like
  `field` was followed by a regular call.
- **Map/struct update crash** — `%{acc | total: x}` syntax crashed the abstract
  normalizer because the `|` pipe in maps isn't a key-value pair. Field sorting
  now only applies to flat keyword lists.
- **Glob matching** — Replaced fragile hand-rolled regex glob with
  `Path.wildcard` expansion. Handles `?`, character classes, and edge cases.
- **Module name resolution** — `BehaviourSuggestion` now reads the `defmodule`
  alias from the file AST instead of deriving from the file path, which broke
  on acronyms like `ExDNA`, `HTTP`, `API`.
- **HTML report dead links** — Location `<a>` tags now use `file://` URIs
  instead of `href="#"`.

### Improvements

- **Compiler runs full pipeline** — The incremental `Mix.Task.Compiler` now
  runs Type-I/II/III detection instead of only Type-I. Cache entries store
  parsed ASTs to support re-fingerprinting with different configs.
- **`detection_time_ms` populated** — Report stats now include actual timing
  via `:timer.tc` instead of hardcoded 0.
- **`--max-clones` CLI flag** — Exits with code 1 only when the clone count
  exceeds the budget, enabling gradual adoption in brownfield projects.
- **Lazy `source_snippets`** — `Macro.to_string` conversion deferred to access
  time via `Clone.source_snippets/1`, avoiding eager serialization of every
  fragment during detection.
- **Report file counting** — Uses `Pipeline.collect_files` instead of
  re-expanding paths independently.
- **HTML report uses EEx** — Layout extracted from string interpolation into
  a proper `html.html.eex` template.

## 1.2.2

- Skip `__block__` nodes in fingerprinting

## 1.2.1

- Harden Credo duplicate issue reporting

## 1.2.0

- Detect duplicated multi-clause functions
- Consecutive `def`/`defp` clauses with the same name/arity are analyzed
  as a single unit

## 1.1.0

- Credo integration via `ExDNA.Credo` check
- `Detector.run/2` accepts pre-parsed ASTs

## 1.0.0

- Initial release
- Type-I/II/III clone detection
- Smart naming for refactoring suggestions
- Cross-file grouping
- `@no_clone` annotation
- Incremental `Mix.Task.Compiler`
- LSP server
- Console, JSON, HTML reporters
