#!/usr/bin/env bats
# Unit tests for `sluice init` stack detection (no Docker: fast, never flaky). setup_file writes a
# synthetic manifest per fixture and runs `sluice init` once; each @test asserts one detection on the
# generated sluice.config.sh. Ported from init-detection.sh - a missed expectation is now a real
# failure (the old has/hasnt counter could be skimmed past).
load test_helper/common

# emit DIR (under $WORK), seed it with files via a callback, then run `sluice init` in it.
_init() { ( cd "$WORK/$1" && "$SLUICE" init ) >/dev/null 2>&1; }

setup_file() {
  export WORK; WORK="$(mktemp -d)"
  local d
  for d in node-vite node-pnpm-port node-next node-bun node-yarn node-bound \
           py-fastapi py-django py-uv py-flask py-ver py-pipenv deno ruby ruby-rails \
           rust go rust-lock go-lock ruby-lock java-maven java-gradle php dotnet elixir dart gmake generic poly force upd; do mkdir -p "$WORK/$d"; done

  printf '{"scripts":{"dev":"vite"},"devDependencies":{"vite":"^5"}}\n' > "$WORK/node-vite/package.json"; _init node-vite
  printf '{"scripts":{"dev":"vite --port 4000"},"devDependencies":{"vite":"^5"}}\n' > "$WORK/node-pnpm-port/package.json"; : > "$WORK/node-pnpm-port/pnpm-lock.yaml"; _init node-pnpm-port
  printf '{"scripts":{"dev":"next dev"},"dependencies":{"next":"14"}}\n' > "$WORK/node-next/package.json"; _init node-next
  printf '{"packageManager":"bun@1.1.0","scripts":{"dev":"vite"},"devDependencies":{"vite":"^5"}}\n' > "$WORK/node-bun/package.json"; _init node-bun
  printf '{"scripts":{"dev":"vite"},"devDependencies":{"vite":"^5"}}\n' > "$WORK/node-yarn/package.json"; : > "$WORK/node-yarn/yarn.lock"; _init node-yarn
  printf '{"scripts":{"dev":"vite --host 0.0.0.0 --port 7777"},"devDependencies":{"vite":"^5"}}\n' > "$WORK/node-bound/package.json"; _init node-bound

  printf 'fastapi\nuvicorn\n' > "$WORK/py-fastapi/requirements.txt"; : > "$WORK/py-fastapi/main.py"; _init py-fastapi
  : > "$WORK/py-django/manage.py"; printf '[tool.poetry]\nname="x"\n' > "$WORK/py-django/pyproject.toml"; : > "$WORK/py-django/poetry.lock"; _init py-django
  printf '[project]\nname="x"\ndependencies=["fastapi","uvicorn"]\n' > "$WORK/py-uv/pyproject.toml"; : > "$WORK/py-uv/uv.lock"; : > "$WORK/py-uv/main.py"; _init py-uv
  printf 'flask\n' > "$WORK/py-flask/requirements.txt"; : > "$WORK/py-flask/app.py"; _init py-flask
  printf '3.11\n' > "$WORK/py-ver/.python-version"; printf 'requests\n' > "$WORK/py-ver/requirements.txt"; _init py-ver
  printf '[[source]]\nurl = "https://pypi.org/simple"\n[packages]\nflask = "*"\n' > "$WORK/py-pipenv/Pipfile"; : > "$WORK/py-pipenv/app.py"; _init py-pipenv

  printf '{"tasks":{"dev":"deno run -A main.ts"}}\n' > "$WORK/deno/deno.json"; _init deno
  printf 'source "https://rubygems.org"\ngem "sinatra"\n' > "$WORK/ruby/Gemfile"; _init ruby
  printf 'source "https://rubygems.org"\ngem "rails", "~> 7"\n' > "$WORK/ruby-rails/Gemfile"; _init ruby-rails
  printf 'source "https://rubygems.org"\ngem "sinatra"\n' > "$WORK/ruby-lock/Gemfile"; : > "$WORK/ruby-lock/Gemfile.lock"; : > "$WORK/ruby-lock/app.rb"; _init ruby-lock
  printf '[package]\nname="x"\n' > "$WORK/rust/Cargo.toml"; _init rust
  printf 'module x\ngo 1.22\n' > "$WORK/go/go.mod"; _init go
  printf '[package]\nname="x"\n' > "$WORK/rust-lock/Cargo.toml"; : > "$WORK/rust-lock/Cargo.lock"; _init rust-lock
  printf 'module x\ngo 1.22\n' > "$WORK/go-lock/go.mod"; : > "$WORK/go-lock/go.sum"; _init go-lock

  printf '<project><dependencies><dependency><artifactId>spring-boot-starter-web</artifactId></dependency></dependencies></project>\n' > "$WORK/java-maven/pom.xml"; _init java-maven
  printf 'plugins { id "application" }\n' > "$WORK/java-gradle/build.gradle"; _init java-gradle
  printf '{"require":{"monolog/monolog":"^3"}}\n' > "$WORK/php/composer.json"; _init php
  printf '<Project Sdk="Microsoft.NET.Sdk.Web"></Project>\n' > "$WORK/dotnet/app.csproj"; _init dotnet
  printf 'defmodule X.MixProject do\n  def project, do: [deps: [{:phoenix, "~> 1.7"}]]\nend\n' > "$WORK/elixir/mix.exs"; _init elixir
  printf 'name: myapp\nenvironment:\n  sdk: ">=3.0.0"\n' > "$WORK/dart/pubspec.yaml"; _init dart
  printf 'run:\n\techo hi\n' > "$WORK/gmake/Makefile"; _init gmake

  _init generic
  printf '{"scripts":{"dev":"vite"},"devDependencies":{"vite":"^5"}}\n' > "$WORK/poly/package.json"; printf 'fastapi\n' > "$WORK/poly/requirements.txt"; _init poly
  printf '{"scripts":{"dev":"vite"},"devDependencies":{"vite":"^5"}}\n' > "$WORK/force/package.json"; _init force

  # --update: a stale config with a manual env var + custom allowlist + uncommented hardening; refresh detection.
  printf '{"scripts":{"dev":"vite"},"devDependencies":{"vite":"^5"}}\n' > "$WORK/upd/package.json"
  printf 'SLUICE_EXTRA_PKGS="oldpkg"\nSLUICE_PORTS="9999"\nSLUICE_RUN_CMD="echo stale"\nSLUICE_ALLOW_DOMAINS="my.custom.host"\nSLUICE_ENV="MY_TOKEN"\nSLUICE_SECCOMP=hardened\n' > "$WORK/upd/sluice.config.sh"
  ( cd "$WORK/upd" && SLUICE_YES=1 "$SLUICE" init --update ) >/dev/null 2>&1
}

teardown_file() { rm -rf "$WORK"; }

# grep the generated config for a literal substring (PASS) / its absence.
has()   { grep -qF -- "$2" "$WORK/$1/sluice.config.sh"; }
hasnt() { ! grep -qF -- "$2" "$WORK/$1/sluice.config.sh"; }

@test "node/vite: dev-script port + run cmd" {
  has node-vite 'SLUICE_PORTS="5173"' &&
  has node-vite 'npm install && npm run dev -- --host 0.0.0.0 --port 5173'
}
@test "node/pnpm: manager + honored port + run cmd" {
  has node-pnpm-port 'SLUICE_EXTRA_NPM="pnpm"' &&
  has node-pnpm-port 'SLUICE_PORTS="4000"' &&
  has node-pnpm-port 'pnpm install && pnpm run dev -- --host 0.0.0.0 --port 4000'
}
@test "node/next: -H/-p flags" { has node-next 'npm run dev -- -H 0.0.0.0 -p 3000'; }
@test "node/bun: apk + run cmd" {
  has node-bun 'SLUICE_EXTRA_PKGS="bun"' &&
  has node-bun 'bun install && bun run dev'
}
@test "node/yarn: manager + run cmd" {
  has node-yarn 'SLUICE_EXTRA_NPM="yarn"' &&
  has node-yarn 'yarn install && yarn dev --'
}
@test "node/bound: honors port, runs as-is, no duplicate flags" {
  has   node-bound 'SLUICE_PORTS="7777"' &&
  has   node-bound 'npm install && npm run dev"' &&
  hasnt node-bound 'npm run dev -- '
}

@test "py/fastapi: pkgs + uvicorn entry + user pip install" {
  has py-fastapi 'SLUICE_EXTRA_PKGS="python-3.12 py3.12-pip"' &&
  has py-fastapi 'uvicorn main:app --host 0.0.0.0 --port 8000' &&
  has py-fastapi 'export PATH="$HOME/.local/bin:$PATH"; pip install --user -r requirements.txt'
}
@test "py/poetry+django: pkg + runserver" {
  has py-django 'py3.12-pip poetry' &&
  has py-django 'poetry install && poetry run python manage.py runserver 0.0.0.0:8000'
}
@test "py/uv: pkg + run cmd" {
  has py-uv 'py3.12-pip uv' &&
  has py-uv 'uv sync && uv run uvicorn main:app'
}
@test "py/flask: run + port" {
  has py-flask 'flask --app app run --host 0.0.0.0 --port 5000' &&
  has py-flask 'SLUICE_PORTS="5000"'
}
@test "py/.python-version 3.11 honored" { has py-ver 'SLUICE_EXTRA_PKGS="python-3.11 py3.11-pip"'; }
@test "py/pipenv: setup + run cmd + detection line" {
  has py-pipenv 'SLUICE_SETUP_CMDS="pip install --user pipenv"' &&
  has py-pipenv 'pipenv install && pipenv run flask --app app run' &&
  has py-pipenv 'detected: python-3.12/pipenv (flask)'
}

@test "deno: apk + run cmd" {
  has deno 'SLUICE_EXTRA_PKGS="deno"' &&
  has deno 'SLUICE_RUN_CMD="deno task dev"'
}
@test "ruby: native-ext toolchain + bindir mkdir + GEM_HOME" {
  has ruby 'SLUICE_EXTRA_PKGS="ruby-3.3 ruby-3.3-dev build-base linux-headers"' &&
  has ruby 'mkdir -p "$HOME/.local/bin" "$HOME/.gem/ruby"' &&
  has ruby 'export GEM_HOME="$HOME/.gem/ruby"'
}
@test "ruby/rails: port + server" {
  has ruby-rails 'SLUICE_PORTS="3000"' &&
  has ruby-rails 'bundle exec rails server -b 0.0.0.0 -p 3000'
}
@test "ruby+lock: F2 prefetch (bundle install at build, no rubygems)" {
  has ruby-lock 'SLUICE_PREFETCH_FILES="Gemfile Gemfile.lock"' &&
  has ruby-lock 'SLUICE_ALLOW_DOMAINS=""' &&
  has ruby-lock 'detected: ruby-3.3 (prefetched)'
}
@test "py/pip+requirements: F2 prefetch (deps installed at build, no pypi)" {
  has py-fastapi 'SLUICE_PREFETCH_FILES="requirements.txt"' &&
  has py-fastapi 'SLUICE_ALLOW_DOMAINS=""'
}
@test "rust: build pkgs + run cmd" {
  has rust 'SLUICE_EXTRA_PKGS="rust build-base"' &&
  has rust 'SLUICE_RUN_CMD="cargo run"'
}
@test "go: apk + run cmd" {
  has go 'SLUICE_EXTRA_PKGS="go"' &&
  has go 'SLUICE_RUN_CMD="go run ."'
}
@test "rust+lock: F2 prefetch (cargo fetch at build, offline run, no crates.io)" {
  has rust-lock 'SLUICE_PREFETCH_CMD="cargo fetch"' &&
  has rust-lock 'SLUICE_RUN_CMD="cargo run --offline"' &&
  has rust-lock 'SLUICE_ALLOW_DOMAINS=""'
}
@test "go+lock: F2 prefetch (go mod download at build, GOPROXY=off run, no go proxy)" {
  has go-lock 'SLUICE_PREFETCH_FILES="go.mod go.sum"' &&
  has go-lock 'SLUICE_RUN_CMD="GOPROXY=off go run ."' &&
  has go-lock 'SLUICE_ALLOW_DOMAINS=""'
}

@test "java/maven+spring: jdk+maven pkgs, JAVA_HOME, spring-boot run, port" {
  has java-maven 'SLUICE_EXTRA_PKGS="openjdk-21 maven"' &&
  has java-maven 'export JAVA_HOME=/usr/lib/jvm/java-21-openjdk' &&
  has java-maven 'mvn -q spring-boot:run' &&
  has java-maven 'SLUICE_PORTS="8080"' &&
  has java-maven 'detected: java/maven (spring-boot)'
}
@test "java/gradle: jdk+gradle pkgs, gradle run, gradle registry" {
  has java-gradle 'SLUICE_EXTRA_PKGS="openjdk-21 gradle"' &&
  has java-gradle 'gradle run' &&
  has java-gradle 'plugins.gradle.org'
}
@test "php: php+composer pkgs, built-in server, packagist" {
  has php 'SLUICE_EXTRA_PKGS="php composer"' &&
  has php 'composer install && php -S 0.0.0.0:8000' &&
  has php 'repo.packagist.org'
}
@test "dotnet: sdk pkg, dotnet run urls, nuget" {
  has dotnet 'SLUICE_EXTRA_PKGS="dotnet-10-sdk"' &&
  has dotnet 'dotnet run --urls http://0.0.0.0:8080' &&
  has dotnet 'api.nuget.org'
}
@test "elixir/phoenix: elixir pkg, phx.server, port, hex" {
  has elixir 'SLUICE_EXTRA_PKGS="elixir"' &&
  has elixir 'mix deps.get && mix phx.server' &&
  has elixir 'SLUICE_PORTS="4000"' &&
  has elixir 'detected: elixir/phoenix'
}
@test "dart: dart pkg, pub get + run, pub.dev" {
  has dart 'SLUICE_EXTRA_PKGS="dart"' &&
  has dart 'dart pub get && dart run' &&
  has dart 'pub.dev'
}
@test "generic+Makefile: run cmd sourced from a make target" {
  has gmake 'SLUICE_RUN_CMD="make run"' &&
  has gmake 'SLUICE_EXTRA_PKGS="make"'
}
@test "scaffold: hardening knobs present as commented options (F3)" {
  has node-vite '# SLUICE_SECCOMP=hardened' &&
  has node-vite '# SLUICE_WORKSPACE=overlay'
}

@test "generic: bash run cmd + no-stack note" {
  has generic 'SLUICE_RUN_CMD="bash"' &&
  has generic 'no known stack detected'
}
@test "polyglot: targets node, flags python" {
  has poly 'detected: node/npm (vite)' &&
  has poly 'also saw manifests for: python'
}

@test "force: refuses without --force, overwrites with it" {
  run bash -c "cd '$WORK/force' && '$SLUICE' init"
  assert_failure
  run bash -c "cd '$WORK/force' && '$SLUICE' init --force"
  assert_success
}

@test "update: refreshes detected fields (run cmd + port)" {
  has upd 'SLUICE_RUN_CMD="npm install && npm run dev -- --host 0.0.0.0 --port 5173"' &&
  has upd 'SLUICE_PORTS="5173"'
}
@test "update: preserves allowlist + env + uncommented hardening" {
  has upd 'SLUICE_ALLOW_DOMAINS="my.custom.host"' &&
  has upd 'SLUICE_ENV="MY_TOKEN"' &&
  has upd 'SLUICE_SECCOMP=hardened'
}
@test "update: refuses when there is no config to update" {
  run bash -c "d=\"\$(mktemp -d)\"; cd \"\$d\" && '$SLUICE' init --update"
  assert_failure
}
