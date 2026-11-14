# Conformance suite

Executable contract for bash, node, python, and powershell behavior.

```
conformance/
├── run.py
└── cases/*.json
```

Case shape:

```json
{
  "env": { "PMSEC_PNPM_VERSION": "11.0.0" },
  "setup": { "<rel-path>": "<file body>" },
  "pre": [["pmsec", "args"]],
  "args": ["pmsec", "args"],
  "expected_exit": 0,
  "expected_json": {},
  "expected_files": { "<rel-path>": "<exact file body after run>" }
}
```

Optional `env` entries override the runner defaults for both `pre` and the
asserted invocation; the literal `<HOME>` in env values expands to the case
temp dir. `<HOME>` in `expected_json` is likewise replaced with the temp dir
when comparing output.

Each `pre` step must exit 0 — a nonzero exit fails the case, and the report
carries the step's exit code, stdout, and stderr. In `expected_files`, a
`null` value asserts the file does not exist; any other value is the exact
expected file body.

Every case runs against a pinned environment: `HOME`, `XDG_CONFIG_HOME`,
`COMPOSER_HOME`, and `MISE_SYSTEM_CONFIG_DIR` (`<HOME>/etc-mise`, so a host
`/etc/mise/miserc.toml` can never reach a case) point inside the temp dir,
and `PMSEC_<TOOL>_VERSION` is `none` for every tool pmsec supports, so no
host-installed version leaks into the output. A case can override a tool's
reported version in `env`, e.g. `PMSEC_MISE_VERSION`. Existing mise cases
rely on the default `none` (mise undetectable).

No port selects a mise config mode by version yet. Fixtures that pin
`PMSEC_MISE_VERSION=2026.11.0` (planned new config mode) or `2026.10.25`
(old mise, legacy mode) are added together with that implementation.

## Run

```sh
python3 conformance/run.py --impl bash
python3 conformance/run.py --impl node
PYTHONPATH=python/src python3 conformance/run.py --impl python
pwsh -NoProfile -Command "python3 conformance/run.py --impl powershell"
```

Use `--case <stem>` for one case.

## Add a Case

1. Add `cases/<name>.json`.
2. Run every implementation.
3. Fix the port, not the assertion, when behavior disagrees.

There are no pending or skipped cases: a fixture is added only together
with the implementation on all four ports.
