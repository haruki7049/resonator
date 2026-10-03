# Agent Guidelines for `resonator`

This document defines core principles, architectural invariants, and non-negotiable safety rules for AI agents working on the `resonator` repository.

______________________________________________________________________

## 1. Project Overview & Architecture

`resonator` is a library of voice-routing structures in Zig. It decides *which lane* a note goes to and *where and how transposed* a canon voice plays it; it does not hold, schedule, or render audio.

- **`std` + `meters` Only**: The only dependency is [`meters`](https://github.com/haruki7049/meters) (`Position`). Do not add `lightmix` or any audio package; scheduling and rendering belong to a sequencer such as [`sequencer`](https://github.com/haruki7049/sequencer). Do not add a pitch library such as [`pitches`](https://github.com/haruki7049/pitches) either: a voice reports its transposition as semitones (`totalSemitones`), and applying it to a pitch is the consumer's job.
- **Library Package**: The public module is registered as `resonator` via `b.addModule` in `build.zig`, so downstream projects consume it with `b.dependency("resonator", .{ .target = target, .optimize = optimize })`.
- **Upstream Boundary**: `meters` is pinned to a commit hash in `build.zig.zon`, and `src/root.zig` re-exports it as `resonator.meters`. Downstream packages also depend on `meters` directly and test that both paths resolve to one `meters.Position` type, so `resonator` must pin the same `meters` commit as its consumers. Bump it only together with them (see "Updating dependencies" in [Section 3](#3-verification-commands)).
- **Downstream Consumers**: [`sequencer`](https://github.com/haruki7049/sequencer) (re-exports `Instrument` and builds instruments in `Sequencer.createInstrument`) and [`pulse`](https://github.com/haruki7049/pulse) pin `resonator` to a commit hash. A change here reaches them only when they bump that pin. Treat a change to a public type's fields, a function signature, an error, or the ownership of `Instrument.string_indices` as a breaking change, and state it in the PR description.
- **Target Language Version**: Zig `0.16.0`, matching `minimum_zig_version` in `build.zig.zon` and the toolchain pinned in `flake.nix`.
- **Development Environment**: Managed with Nix, `direnv`, and `nix-direnv`. Formatting across all languages is handled via `treefmt` (nixfmt, zig fmt, actionlint, mdformat, shellcheck, shfmt). `.deps.nix` is the `zon2nix` lockfile of the Zig dependencies for the Nix build.
- **Source Layout** (`src/`):
  - `root.zig`: Re-exports `meters`, `Instrument` and `Stagger`.
  - `instrument.zig`: `Instrument`, a file struct with `name` and one track index per string (`init`, `deinit`, `stringCount`, `getTrackIndex`).
  - `stagger.zig`: `Stagger.VoiceConfig(T)`, a canon voice (`bar_offset`, `beat_offset`, `semitones`, `octaves`, `string_index`, `volume`) with `totalSemitones`, `offsetPosition`, `eql` and `eqlAll`.
- **Domain Conventions**:
  - **One string, one monophonic lane**: Each string of an `Instrument` maps to its own track. Notes on different strings ring together; a new note on the same string replaces the previous one. Keep this model: the truncation itself is implemented downstream, and it relies on it.
  - Strings are 0-indexed from the lowest string. An out-of-range index returns `error.InvalidStringIndex`; never wrap or clamp it silently.
  - `Instrument.init` takes ownership of `string_indices`, and `deinit` frees it with the allocator passed in.
  - Positions are `meters` types. Do not duplicate them here.
  - `resonator` has no pitch type. Transposition is an integer number of semitones, an octave counting as 12.
  - `VoiceConfig.eql` compares floating-point fields within `1e-6`; keep that tolerance in sync with its doc comment.

______________________________________________________________________

## 2. Strict Safety & Operational Rules (Always Enforced)

- **A change request implies commit, push and PR**: When the user instructs a change, carry it through to a pull request without asking for confirmation: work on a topic branch created from the latest `origin/main` (or the existing topic branch for that work; never commit on `main`, since it cannot be pushed), pass the verification commands, then `git commit`, `git push` the topic branch, and open a PR with `gh pr create` if none exists. If the branch already has an open PR, push to it and update the PR description when it has become stale.
- **`main` is protected on GitHub (ruleset active)**: A GitHub ruleset on the default branch requires a pull request (0 required approvals, squash merge only), signed commits, linear history and these status checks: `test` (ubuntu, macos, windows), `run-nix-check` and `run-nix-build` (ubuntu, macos), and `validate-pr-title`. It also blocks deletion and non-fast-forward pushes. `git push origin main` will therefore be rejected. AI agents **MUST NEVER** merge PRs (including enabling auto-merge with `gh pr merge --auto`) or execute `git merge` autonomously.
- **NEVER PROPOSE COMMITS OR PUSHES UNPROMPTED**: AI agents **MUST NEVER** prompt the user to commit or push, nor propose commit messages unprompted (e.g. do NOT ask "Would you like me to commit and push?"). When instructed by the user or when creating/updating pull requests on topic branches, agents may execute `git commit` and `git push` directly without seeking confirmation.
- **Mandatory Human Approval**: AI agents may create branches, create commits, push topic branches, propose PRs, format code, and run test suites, but the final action of merging changes into `main` rests strictly with the human maintainer.
- **Verification Before Submitting**: All changes must pass the commands in [Section 3](#3-verification-commands).
- **Conventional Commits**: Use conventional commit prefixes (`feat:`, `fix:`, `refactor:`, `docs:`, `build:`, `ci:`, `test:`). The PR title must follow the same format; `validate-pr-title` checks it.
- **No Issue Numbers in Commit Messages**: Do not include issue numbers (e.g. `(#5)` or `#5`) anywhere in a commit message, summary or body, or in a PR title. Squash merges copy every commit message into `main`, so a `Closes #5` in a commit body can close an issue the PR was never meant to close. Link issues only from the PR description with a closing keyword (e.g. `Closes #5`). The ` (#N)` suffix GitHub appends to a squash-merge summary is the one exception.
- **Explicit Milestone Assignment Only**: AI agents **MUST NEVER** attach or set GitHub Milestones on Pull Requests or Issues unless explicitly requested by the user.
- **Evidence First**: Base all answers and actions on actual file contents and command output. Never speculate or assume.
- **Non-Destructive**: Never perform irreversible actions (file deletions, hard resets, rewriting pushed history such as amending or rebasing pushed commits and force-pushing, pushing to `main`) without explicit user approval. Ordinary pushes of new commits to a topic branch don't need approval (see above).
- **Targeted Edits**: Make minimal, logical changes strictly necessary for the request. Do not modify unrelated files.
- **English-Only Documentation**: All repository documentation, code comments, commit messages, and PR descriptions must be written strictly in English. Never include Japanese or any non-English language in repository documentation.
- **No Session Links**: Do not include AI session URLs or other internal session identifiers (e.g. a `Claude-Session:` trailer) in commit messages, PR descriptions, issues, or comments. Such links are not accessible from outside the private session, so publishing them in this public repository serves no purpose and only confuses readers. A `Co-Authored-By:` trailer is fine. Exception: if the user explicitly states the session is public and instructs the agent to include its URL, doing so is allowed.

______________________________________________________________________

## 3. Verification Commands

Run these inside the Nix development shell (`nix develop` or `direnv allow`). CI runs the same set.

| Task | Command | Description |
| :--- | :--- | :--- |
| **Check formatting** | `treefmt --fail-on-change` | Checks every language treefmt covers; `zig fmt --check .` checks Zig files only |
| **Build** | `zig build` | Builds the static library |
| **Run tests** | `zig build test` | Runs every unit test in `src/` |
| **Check the flake** | `nix flake check` | Runs the flake checks, including the treefmt check and the package build |

**Updating dependencies**: After changing a dependency in `build.zig.zon` (`zig fetch --save <url>`), run `zon2nix > .deps.nix` in the dev shell, then `treefmt`, and commit both files together. The sandboxed Nix build has no network access and pre-fetches the Zig dependencies from `.deps.nix` (see `flake.nix`).

______________________________________________________________________

## 4. Coding Conventions

- **Comments**: Every public declaration has a `///` doc comment, and every file starts with a `//!` comment that says what it contains. Comments are in English.
- **Naming**:
  - `PascalCase` for types and for files imported as a struct (`Instrument`, `Stagger`, `VoiceConfig`).
  - `camelCase` for functions and methods (`getTrackIndex`, `offsetPosition`, `totalSemitones`).
  - `snake_case` for variables, parameters and struct fields (`string_indices`, `bar_offset`, `string_index`).
  - Comptime type parameters are always a single uppercase character (`comptime T: type`). Multi-character names such as `comptime SampleType: type` are prohibited.
  - Error tags are `PascalCase` (`error.InvalidStringIndex`).
- **Generic Types**: A type parameterized by the sample type is a function returning a type (`pub fn VoiceConfig(comptime T: type) type`) and must not favor one floating-point precision.
- **Tests**: Keep tests next to the code they cover, in the same file; `src/root.zig` holds the tests that combine `Instrument`, `Stagger` and `meters`. Every file ends with `test { std.testing.refAllDecls(@This()); }`.

______________________________________________________________________

## 5. Status Assessment Workflow

When asked to check status, assess the situation, or understand workspace context:

1. **Local Git State**: Inspect working tree (`git status -s -b`) and recent commits (`git log -n 5 --oneline`).
1. **GitHub PRs**: Check PR status (`gh pr status`) and current PR details (`gh pr view`).
1. **GitHub Issues**: Check relevant open issues (`gh issue list --limit 5`).
1. **Environment Health**: Run the commands in [Section 3](#3-verification-commands).
1. **Synthesis**: Report a concise, structured status covering local state, remote GitHub state, and environment health.
