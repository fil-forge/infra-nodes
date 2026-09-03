# The checks CI runs, so the same commands are available before pushing.
#
# There is nothing to build here: a node deploys itself by pulling origin/main
# and running the host scripts, so `check` is the whole surface. Each job in
# .github/workflows/check.yml calls one of these targets and nothing else,
# which is what keeps local and CI from drifting.

# bash for `set -o pipefail` and for the loops below. .SHELLFLAGS would be the
# tidier place for the flags, but the make macOS ships is 3.81, which ignores
# it, so each multi-command recipe sets them itself.
SHELL := /bin/bash

.PHONY: check
check: check-tofu check-shell check-compose

# -backend=false because validating a root does not need its state, and reaching
# the state bucket would need credentials the CI job does not have.
.PHONY: check-tofu
check-tofu:
	tofu fmt -check -recursive terraform/
	@set -euo pipefail; \
	for root in terraform/envs/*/ terraform/envs/*/*/; do \
	  [ -f "$$root/versions.tofu" ] || continue; \
	  echo "==> $$root"; \
	  tofu -chdir="$$root" init -backend=false -input=false; \
	  tofu -chdir="$$root" validate; \
	done

# The host scripts run as root on a box nobody watches, so a quoting mistake in
# one of them is an outage rather than a typo.
#
# -x follows the `. lib.sh` in each script, so the helpers it defines are checked
# in the context that uses them. -P SCRIPTDIR is what lets it find that file: the
# scripts source it through a `$(dirname ...)` that no static check can resolve.
# The CI scripts source nothing, so they need neither flag.
.PHONY: check-shell
check-shell:
	shellcheck -x -P SCRIPTDIR scripts/host/*.sh scripts/operator/*.sh
	shellcheck nodes/*/apps/config/piri/entrypoint.sh
	shellcheck scripts/ci/*.sh

# `compose config` resolves every interpolation, so it catches a variable a
# compose file expects and no env file supplies — which on a node shows up as a
# service starting with an empty password.
.PHONY: check-compose
check-compose:
	@set -euo pipefail; \
	secrets="$$(mktemp "$${TMPDIR:-/tmp}/filone-check-compose.XXXXXX")"; \
	trap 'rm -f "$$secrets"' EXIT; \
	printf '%s\n' \
	  SEAL_TOKEN=x \
	  POSTGRES_ADMIN_PASSWORD=x \
	  PIRI_POSTGRES_PASSWORD=x \
	  INGOT_POSTGRES_PASSWORD=x \
	  CHAIN_RPC_TOKEN=x \
	  GRAFANA_PUSH_TOKEN=x >"$$secrets"; \
	for node in nodes/*/; do \
	  for project in platform apps; do \
	    echo "==> $${node}$${project}"; \
	    docker compose \
	      --project-directory "$${node}$${project}" \
	      --env-file "$${node}node.env" \
	      --env-file "$${node}$${project}/versions.env" \
	      --env-file "$$secrets" \
	      config >/dev/null; \
	  done; \
	done
