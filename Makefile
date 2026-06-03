# sluice dev tasks.
#   make test         - gate bats suites against the local engine (run before pushing). Docker Desktop
#                       runs boxes in a Linux VM, so this exercises the Linux behaviour CI checks.
#   make test-nightly - the heavy nightly suites (lock/learn/runtimes/nix/agents/control-plane).
#   make structure    - container-structure-test the base image (baked invariants: no sudo, uid 1000).
#   make lint         - shellcheck + shfmt over the launcher.
#   make setup        - fetch the vendored bats submodules (after a fresh clone).
BATS := test/bats/bin/bats
GATE_BATS := $(filter-out $(wildcard test/nightly-*.bats),$(wildcard test/*.bats))

.PHONY: test test-nightly structure lint setup
setup:
	git submodule update --init --recursive

test:
	@test -x $(BATS) || { echo "bats missing - run 'make setup'"; exit 1; }
	$(BATS) --print-output-on-failure $(GATE_BATS)

test-nightly:
	@test -x $(BATS) || { echo "bats missing - run 'make setup'"; exit 1; }
	$(BATS) --print-output-on-failure test/nightly-*.bats

structure:
	docker build --target base -t sluice-base:gate core/
	@command -v container-structure-test >/dev/null 2>&1 \
	  && container-structure-test test --image sluice-base:gate --config tests/structure.yaml \
	  || echo "container-structure-test absent (brew install container-structure-test) - skipping image invariants"

lint:
	shellcheck -S warning bin/sluice
	@command -v shfmt >/dev/null 2>&1 && shfmt -d -i 2 -ci bin/sluice || echo "shfmt absent (brew install shfmt) - skipping format check"
