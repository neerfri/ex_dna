# Changelog

## Unreleased

### Detection improvements

- **Sub-hash Jaccard pre-filter for Type-III** — Each fragment carries a set
  of lightweight sub-hashes from its child subtrees, computed during the
  fingerprint walk (zero extra cost). An inverted index on sub-hashes generates
  candidate pairs without O(n²) pairwise iteration — only fragments sharing
  structural sub-components are compared. Jaccard similarity then pre-filters
  before expensive tree edit distance.
- **Sibling window fingerprinting** — Consecutive statements in module bodies
  are fingerprinted as sliding windows (2–4 siblings). Catches clones where
  adjacent `def`s are copied between modules but surrounding code differs.
  Only applies to module-level blocks (not function bodies) to avoid
  combinatorial blowup.
- **Cross-arity delegation grouping** — `def foo(x), do: foo(x, [])` followed
  by `def foo(x, opts)` are now grouped as a single unit for fingerprinting.
  Enables detection of duplicated wrapper+body patterns across modules.
- **Struct/map field order normalization** — `%User{name: x, age: y}` and
  `%User{age: y, name: x}` now produce the same hash in abstract mode (Type-II).
- **Minimum fuzzy mass** — Type-III detection only considers fragments with
  mass ≥ 2× `min_mass`, filtering out tiny fragments that produce noise and
  dominate runtime.

### Performance

- **Inverted index candidate generation** — Replaced O(n²) pairwise comparison
  in fuzzy detection with an inverted index on sub-hashes. Posting lists
  exceeding 100 entries are skipped as structural noise.
- **Pre-normalized ASTs** — ASTs are normalized once per mass bucket instead of
  once per pair comparison.
- Tested on 18 real-world projects (up to 554 files): all complete in under 6s
  with full Type-I/II/III detection enabled.

### Bug fixes

- **`has_dsl_call?` logic error** — The macro suggestion detector was resetting
  its `found` flag on non-DSL nodes, losing detection when a DSL call like
  `field` was followed by a regular call.
- **Map/struct update crash** — `%{acc | total: x}` syntax crashed the abstract
  normalizer because the `|` pipe in maps isn't a key-value pair. Field sorting
  now only applies to flat keyword lists.
- **`Macro.to_string` crash on synthetic ASTs** — Window fragments and
  anti-unifier output can produce ASTs that crash `Macro.to_string`. Now
  rescued gracefully.
- **`__MODULE__` in remote calls** — `CharacteristicVector` crashed when
  `__MODULE__.function()` appeared in code because `parts` contained an AST
  node instead of an atom.
- **Glob matching** — Replaced fragile hand-rolled regex glob with
  `Path.wildcard` expansion.
- **Module name resolution** — `BehaviourSuggestion` now reads the `defmodule`
  alias from the file AST instead of deriving from the file path, which broke
  on acronyms like `ExDNA`, `HTTP`, `API`.
- **HTML report links** — Location `<a>` tags now use `file://` URIs with
  `#L{line}` fragments instead of dead `href="#"`.
- **`file_uri` used invalid `:line` suffix** — Changed to standard `#L42`
  fragment syntax.

### Improvements

- **Compiler runs full pipeline** — The incremental `Mix.Task.Compiler` now
  runs Type-I/II/III detection instead of only Type-I. Cache entries store
  parsed ASTs to support re-fingerprinting with different configs.
- **`detection_time_ms` populated** — Report stats now include actual timing
  via `:timer.tc` instead of hardcoded 0.
- **`--max-clones` CLI flag** — Exits with code 1 only when the clone count
  exceeds the budget, enabling gradual adoption in brownfield projects.
- **Report file counting** — Uses `Pipeline.collect_files` instead of
  re-expanding paths independently.
- **HTML report uses EEx** — Layout extracted from string interpolation into
  a proper `html.html.eex` template.
- **Zero dialyzer suppressions** — Added `:mix` and `:credo` to PLT, removed
  `.dialyzer_ignore.exs`. All 18 previously suppressed errors resolved.
- **Replaced duplicate `relative_path/1`** — Three modules defined the same
  helper; all now use `Path.relative_to_cwd/1` from stdlib.

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
