# sluice dev tasks.
#   make test         - gate bats suites against the local engine (run before pushing). Docker Desktop
#                       runs boxes in a Linux VM, so this exercises the Linux behaviour CI checks.
#   make test-nightly - the heavy nightly suites (lock/learn/runtimes/nix/agents/control-plane).
#   make structure    - container-structure-test the base image (baked invariants: no sudo, uid 1000).
#   make lint         - shellcheck the launcher (the correctness gate).
#   make setup        - fetch the vendored bats submodules (after a fresh clone).
#   make build        - assemble bin/sluice from src/*.sh (edit the slices, not bin/sluice).
BATS := test/bats/bin/bats
# Gate suites split by COST, not filename: UNIT needs no container engine (fast, the no-Docker CI
# lane); ENGINE builds real boxes (ACCEPT = the egress/run matrix, SECURITY = the danger knobs).
# CI drives each lane from its target, so the Makefile is the single source of truth (no hand lists).
UNIT_BATS     := test/init-detection.bats test/verify-init-quoting.bats test/verify-install.bats \
                 test/verify-cli.bats test/verify-doctor-checks.bats test/verify-agent-scaffold.bats \
                 test/verify-laundering-gate.bats test/verify-signed-base.bats \
                 test/verify-egress-hostname-gate.bats test/verify-policy-unit.bats \
                 test/verify-receipt-unit.bats test/verify-lock-unit.bats \
                 test/verify-worktree-mount.bats test/verify-doh-case.bats \
                 test/verify-seccomp-leak-unit.bats test/verify-setf-noglob-unit.bats \
                 test/verify-egress-allowlist-failopen.bats test/verify-ls-egress-unit.bats \
                 test/verify-lane-membership-unit.bats test/verify-ci-supplychain-unit.bats \
                 test/verify-fleet-audit-unit.bats test/verify-hostbudget-unit.bats \
                 test/verify-pin-unit.bats test/verify-hardcap-unit.bats \
                 test/verify-allowips-rows-unit.bats test/verify-dnsaudit-unit.bats \
                 test/verify-bump-knobs-unit.bats test/verify-replay-unit.bats \
                 test/verify-podman-userns-unit.bats test/verify-build-hash-unit.bats \
                 test/verify-policy-ceilings-unit.bats test/verify-home-guard-unit.bats \
                 test/verify-drift-render-unit.bats test/verify-awk-data-unit.bats
ACCEPT_BATS   := test/acceptance.bats test/acceptance-bump.bats test/verify-run-default.bats
SECURITY_BATS := $(wildcard test/verify-security-*.bats)
ENGINE_BATS   := $(ACCEPT_BATS) $(SECURITY_BATS)
GATE_BATS     := $(UNIT_BATS) $(ENGINE_BATS)
SRC := $(sort $(wildcard src/*.sh))

.PHONY: test test-unit test-engine test-acceptance test-security test-nightly structure lint lint-ci setup build build-check _bats-check
setup:
	git submodule update --init --recursive
	@git config merge.sluicebuild.name 'regenerate bin/sluice from src/*.sh on conflict'
	@git config merge.sluicebuild.driver 'make build >/dev/null 2>&1; cp -- bin/sluice %A'
	@echo 'registered bin/sluice merge driver (see .gitattributes)'
_bats-check:
	@test -x $(BATS) || { echo "bats missing - run 'make setup'"; exit 1; }

# test = the whole gate; test-unit/-engine/-acceptance/-security = the cost lanes CI runs per job.
test:            _bats-check ; $(BATS) --print-output-on-failure $(GATE_BATS)
test-unit:       _bats-check ; $(BATS) --print-output-on-failure $(UNIT_BATS)
test-engine:     _bats-check ; $(BATS) --print-output-on-failure $(ENGINE_BATS)
test-acceptance: _bats-check ; $(BATS) --print-output-on-failure $(ACCEPT_BATS)
test-security:   _bats-check ; $(BATS) --print-output-on-failure $(SECURITY_BATS)

test-nightly:
	@test -x $(BATS) || { echo "bats missing - run 'make setup'"; exit 1; }
	$(BATS) --print-output-on-failure test/nightly-*.bats

structure:
	docker build --target base -t sluice-base:gate core/
	@command -v container-structure-test >/dev/null 2>&1 \
	  || { echo 'INVARIANTS NOT CHECKED: container-structure-test missing (brew install container-structure-test)'; exit 1; }
	container-structure-test test --image sluice-base:gate --config test/structure.yaml

# shellcheck only (the correctness gate). shfmt was dropped: it expands the deliberate compact
# one-liners and no flag preserves them, so it could never gate the launcher's hand-kept style.
lint:
	shellcheck -S warning bin/sluice

# advisory actionlint over .github/workflows - the same digest-pinned image as the scans.yml lane.
lint-ci:
	docker run --rm --platform linux/amd64 -v "$(CURDIR):/repo" --workdir /repo rhysd/actionlint:1.7.12@sha256:9d36088643581e728c969f35141f88139fec77280b2be23c1f66f8e40e1025e7 -color

# bin/sluice is a GENERATED single-file launcher (assembled from the ordered src/*.sh slices, so the
# curl-one-file install still works). Edit the slices, then `make build`.
build:
	cat $(SRC) > bin/sluice
	chmod +x bin/sluice

build-check:
	@tmp=$$(mktemp); cat $(SRC) > $$tmp; \
	  if diff -u bin/sluice $$tmp >/dev/null; then echo "bin/sluice in sync with src/"; rm -f $$tmp; \
	  else echo "bin/sluice is out of sync with src/ - run 'make build':"; diff -u bin/sluice $$tmp; rm -f $$tmp; exit 1; fi
