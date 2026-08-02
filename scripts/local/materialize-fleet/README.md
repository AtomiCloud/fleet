# materialize-fleet overlay

Source-side templates that `scripts/local/materialize-fleet.sh` lays over the
allowlisted copy so the materialized `AtomiCloud/fleet` product is
**self-contained and green** — it must never reference an excluded surface.

Everything under `overlay/` is copied verbatim onto the target checkout root
_after_ the allowlist rsync, replacing the inherited workspace variants:

| Overlay path                | Why it replaces the inherited file                                                                                                                                                                                                                                                                                                                                                                                                      |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nix/pre-commit.nix`        | Fleet-only hook set. The inherited hooks reference excluded assets (helm charts, `atomi_release.yaml`, release workflows, vendored skills, `CLAUDE.md`, `many-owner` targets, docs-standards markdown). The fleet variant keeps only hooks whose assets ship in the product: `treefmt`, action pin (trusted/non-trusted) and cache-tag checks for the included workflows, executable-shell check, secret scan, nix pin, and ShellCheck. |
| `scripts/ci/pre-commit.sh`  | Drops the inherited `setup.sh`/`skills-sync.sh` call — the product vendors no skills.                                                                                                                                                                                                                                                                                                                                                   |
| `Taskfile.yaml`             | Fleet-only task surface (`lint`, `test`, `test:fleet` → `./scripts/ci/fleet.sh`); no helm-wrapper/cluster/secret includes.                                                                                                                                                                                                                                                                                                              |
| `.github/workflows/ci.yaml` | Reduced CI: `precommit` + `fleet` jobs only (no helm / helm-wrapper).                                                                                                                                                                                                                                                                                                                                                                   |
| `config/action-trust.json`  | Classifies exactly the actions the product workflows use (`AtomiCloud/actions.setup-nix` trusted; `actions/checkout` and `actions/create-github-app-token` non-trusted), so the action-pin hooks pass without the inherited `upsidr/merge-gatekeeper` entry.                                                                                                                                                                            |

Keep every overlay treefmt-clean and in sync with the fleet-owned reusable
workflows and validators it depends on; `materialize-fleet.sh --self-test`
asserts no excluded path is referenced and that every referenced script exists
in the materialized target.
