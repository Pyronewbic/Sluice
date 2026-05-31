#!/usr/bin/env bash
# Unit tests for `sluice init` detection (no Docker: fast, never flaky). Asserts the generated
# sluice.config.sh for synthetic manifests, locking in detection + the toolchain fixes.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUICE="$ROOT/bin/sluice"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
dir()  { local d="$WORK/$1"; mkdir -p "$d"; printf '%s' "$d"; }
init() { ( cd "$1" && "$SLUICE" init ) >/dev/null 2>&1; }
# has DIR LABEL SUBSTRING  -> PASS if the generated config contains the literal substring
has()  { if grep -qF -- "$3" "$1/sluice.config.sh"; then ok "$2"; else bad "$2  [missing: $3]"; fi; }
hasnt(){ if grep -qF -- "$3" "$1/sluice.config.sh"; then bad "$2  [unexpected: $3]"; else ok "$2"; fi; }

echo "== sluice init detection =="

# ---- node: package manager, framework, the real dev-script port, flag spelling ----
d="$(dir node-vite)"
printf '{"scripts":{"dev":"vite"},"devDependencies":{"vite":"^5"}}\n' > "$d/package.json"; init "$d"
has "$d" "node/vite port"        'SLUICE_PORTS="5173"'
has "$d" "node/vite run cmd"     'npm install && npm run dev -- --host 0.0.0.0 --port 5173'

d="$(dir node-pnpm-port)"
printf '{"scripts":{"dev":"vite --port 4000"},"devDependencies":{"vite":"^5"}}\n' > "$d/package.json"
: > "$d/pnpm-lock.yaml"; init "$d"
has "$d" "node/pnpm manager"     'SLUICE_EXTRA_NPM="pnpm"'
has "$d" "node/pnpm honors port" 'SLUICE_PORTS="4000"'
has "$d" "node/pnpm run cmd"     'pnpm install && pnpm run dev -- --host 0.0.0.0 --port 4000'

d="$(dir node-next)"
printf '{"scripts":{"dev":"next dev"},"dependencies":{"next":"14"}}\n' > "$d/package.json"; init "$d"
has "$d" "node/next -H/-p flags" 'npm run dev -- -H 0.0.0.0 -p 3000'

d="$(dir node-bun)"
printf '{"packageManager":"bun@1.1.0","scripts":{"dev":"vite"},"devDependencies":{"vite":"^5"}}\n' > "$d/package.json"; init "$d"
has "$d" "node/bun apk"          'SLUICE_EXTRA_PKGS="bun"'
has "$d" "node/bun run cmd"      'bun install && bun run dev'

d="$(dir node-yarn)"
printf '{"scripts":{"dev":"vite"},"devDependencies":{"vite":"^5"}}\n' > "$d/package.json"
: > "$d/yarn.lock"; init "$d"
has "$d" "node/yarn manager"     'SLUICE_EXTRA_NPM="yarn"'
has "$d" "node/yarn run cmd"     'yarn install && yarn dev --'

d="$(dir node-bound)"
printf '{"scripts":{"dev":"vite --host 0.0.0.0 --port 7777"},"devDependencies":{"vite":"^5"}}\n' > "$d/package.json"; init "$d"
has   "$d" "node/bound honors port" 'SLUICE_PORTS="7777"'
has   "$d" "node/bound runs as-is"  'npm install && npm run dev"'
hasnt "$d" "node/bound no dup flags" 'npm run dev -- '

# ---- python: manager, framework + entry, interpreter version ----
d="$(dir py-fastapi)"
printf 'fastapi\nuvicorn\n' > "$d/requirements.txt"; : > "$d/main.py"; init "$d"
has "$d" "py pkgs"               'SLUICE_EXTRA_PKGS="python-3.12 py3.12-pip"'
has "$d" "py/fastapi uvicorn"    'uvicorn main:app --host 0.0.0.0 --port 8000'
has "$d" "py/pip user install"   'export PATH="$HOME/.local/bin:$PATH"; pip install --user -r requirements.txt'

d="$(dir py-django)"
: > "$d/manage.py"; printf '[tool.poetry]\nname="x"\n' > "$d/pyproject.toml"; : > "$d/poetry.lock"; init "$d"
has "$d" "py/poetry pkg"         'py3.12-pip poetry'
has "$d" "py/django runserver"   'poetry install && poetry run python manage.py runserver 0.0.0.0:8000'

d="$(dir py-uv)"
printf '[project]\nname="x"\ndependencies=["fastapi","uvicorn"]\n' > "$d/pyproject.toml"; : > "$d/uv.lock"; : > "$d/main.py"; init "$d"
has "$d" "py/uv pkg"             'py3.12-pip uv'
has "$d" "py/uv run cmd"         'uv sync && uv run uvicorn main:app'

d="$(dir py-flask)"
printf 'flask\n' > "$d/requirements.txt"; : > "$d/app.py"; init "$d"
has "$d" "py/flask run + port"   'flask --app app run --host 0.0.0.0 --port 5000'
has "$d" "py/flask port"         'SLUICE_PORTS="5000"'

d="$(dir py-ver)"
printf '3.11\n' > "$d/.python-version"; printf 'requests\n' > "$d/requirements.txt"; init "$d"
has "$d" "py/version 3.11"       'SLUICE_EXTRA_PKGS="python-3.11 py3.11-pip"'

# ---- deno ----
d="$(dir deno)"
printf '{"tasks":{"dev":"deno run -A main.ts"}}\n' > "$d/deno.json"; init "$d"
has "$d" "deno apk"              'SLUICE_EXTRA_PKGS="deno"'
has "$d" "deno run cmd"          'SLUICE_RUN_CMD="deno task dev"'

# ---- ruby (locks in the native-extension toolchain + bindir mkdir fixes) ----
d="$(dir ruby)"
printf 'source "https://rubygems.org"\ngem "sinatra"\n' > "$d/Gemfile"; init "$d"
has "$d" "ruby build pkgs"       'SLUICE_EXTRA_PKGS="ruby-3.3 ruby-3.3-dev build-base linux-headers"'
has "$d" "ruby setup mkdir -p"   'mkdir -p "$HOME/.local/bin" "$HOME/.gem/ruby"'
has "$d" "ruby GEM_HOME in run"  'export GEM_HOME="$HOME/.gem/ruby"'

d="$(dir ruby-rails)"
printf 'source "https://rubygems.org"\ngem "rails", "~> 7"\n' > "$d/Gemfile"; init "$d"
has "$d" "ruby/rails port"       'SLUICE_PORTS="3000"'
has "$d" "ruby/rails server"     'bundle exec rails server -b 0.0.0.0 -p 3000'

# ---- rust (locks in the C-linker fix) / go ----
d="$(dir rust)"
printf '[package]\nname="x"\n' > "$d/Cargo.toml"; init "$d"
has "$d" "rust build pkgs"       'SLUICE_EXTRA_PKGS="rust build-base"'
has "$d" "rust run cmd"          'SLUICE_RUN_CMD="cargo run"'

d="$(dir go)"
printf 'module x\ngo 1.22\n' > "$d/go.mod"; init "$d"
has "$d" "go apk"                'SLUICE_EXTRA_PKGS="go"'
has "$d" "go run cmd"            'SLUICE_RUN_CMD="go run ."'

# ---- generic + polyglot ----
d="$(dir generic)"; init "$d"
has "$d" "generic bash"          'SLUICE_RUN_CMD="bash"'

d="$(dir poly)"
printf '{"scripts":{"dev":"vite"},"devDependencies":{"vite":"^5"}}\n' > "$d/package.json"
printf 'fastapi\n' > "$d/requirements.txt"; init "$d"
has "$d" "polyglot targets node" 'detected: node/npm (vite)'
has "$d" "polyglot flags python" 'also saw manifests for: python'

# ---- --force ----
d="$(dir force)"
printf '{"scripts":{"dev":"vite"},"devDependencies":{"vite":"^5"}}\n' > "$d/package.json"; init "$d"
if ( cd "$d" && "$SLUICE" init )        >/dev/null 2>&1; then bad "force: refuses without --force"; else ok "force: refuses without --force"; fi
if ( cd "$d" && "$SLUICE" init --force ) >/dev/null 2>&1; then ok "force: --force overwrites"; else bad "force: --force overwrites"; fi

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
