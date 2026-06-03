_init_json_str()  { printf '%s' "$(grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null | head -1 | sed -E 's/^.*:[[:space:]]*"([^"]*)".*$/\1/')"; }
_init_port_from() { printf '%s' "$(printf '%s' "$1" | grep -oiE -- '(--port|--server\.port|-p|PORT)[ =]+[0-9]+' | grep -oE '[0-9]+' | head -1)"; }
_init_pkg_has()   { grep -qE "\"$2(\"|/)" "$1" 2>/dev/null; }          # dependency / scoped-pkg key
_init_has_script(){ grep -qE "\"$2\"[[:space:]]*:" "$1" 2>/dev/null; } # a package.json/deno.json script
_init_py_has()    { grep -qiE "(^|[^a-zA-Z0-9_.-])$1" "$dir/requirements.txt" "$dir/pyproject.toml" "$dir/Pipfile" 2>/dev/null; }
# Quote a config value: single-quote if it contains $ or " (we never emit a literal single quote).
_init_q()         { case "$1" in *[\$\"]*) printf "'%s'" "$1" ;; *) printf '"%s"' "$1" ;; esac; }
# A run command the project already declares (Procfile web line, or a Makefile/justfile run-ish target),
# so the generic fallback can propose something real instead of 'bash'. Echoes the command; rc 1 if none.
_init_runcmd_from_files() {
  if [ -f "$dir/Procfile" ]; then
    local w; w="$(sed -nE 's/^[a-zA-Z0-9_-]+:[[:space:]]*//p' "$dir/Procfile" 2>/dev/null | head -1)"
    [ -n "$w" ] && { printf '%s' "$w"; return 0; }
  fi
  local mf="" t
  [ -f "$dir/Makefile" ] && mf="$dir/Makefile"
  [ -f "$dir/makefile" ] && mf="$dir/makefile"
  if [ -n "$mf" ]; then
    for t in run dev start serve; do
      grep -qE "^$t:" "$mf" 2>/dev/null && { printf 'make %s' "$t"; return 0; }
    done
  fi
  local jf=""
  [ -f "$dir/justfile" ] && jf="$dir/justfile"
  [ -f "$dir/Justfile" ] && jf="$dir/Justfile"
  if [ -n "$jf" ]; then
    for t in run dev start serve; do
      grep -qE "^$t:" "$jf" 2>/dev/null && { printf 'just %s' "$t"; return 0; }
    done
  fi
  return 1
}

# `sluice init`: scaffold a config from $PWD's manifests (allowlist left to `learn`)
cmd_init() {
  local force=0 update=0
  while [ $# -gt 0 ]; do
    case "$1" in -f|--force) force=1 ;; -u|--update) update=1 ;; *) break ;; esac
    shift
  done
  local dir="$PWD" cfg pj
  cfg="$dir/sluice.config.sh"; pj="$dir/package.json"
  if [ "$update" -eq 1 ]; then
    [ -e "$cfg" ] || die "no sluice.config.sh to update here - run 'sluice init' to create one first."
  elif [ -e "$cfg" ] && [ "$force" -ne 1 ]; then
    die "$cfg already exists - edit it, remove it, re-run with --force, or --update to refresh detection."
  fi

  local stack="generic" detected="generic" extra_pkgs="" extra_npm="" setup="" \
        run_cmd="bash" ports="" allow="" note="" note2="" prefetch_files="" prefetch_cmd=""

  if [ -f "$pj" ]; then
    # node / bun
    stack="node"
    local pm="npm"
    if   [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ]; then pm="bun"
    elif [ -f "$dir/pnpm-lock.yaml" ];    then pm="pnpm"
    elif [ -f "$dir/yarn.lock" ];         then pm="yarn"
    elif [ -f "$dir/package-lock.json" ]; then pm="npm"
    else case "$(_init_json_str "$pj" packageManager)" in
           pnpm*) pm="pnpm" ;; yarn*) pm="yarn" ;; bun*) pm="bun" ;;
         esac
    fi
    case "$pm" in pnpm|yarn) extra_npm="$pm" ;; bun) extra_pkgs="bun" ;; esac

    # framework -> default port + the flag spelling that framework uses + preferred script
    local fw="" port=3000 hostflag="--host 0.0.0.0" portflag="--port" pref="dev"
    if   _init_pkg_has "$pj" '@angular/core'; then fw="angular";    port=4200; pref="start"
    elif _init_pkg_has "$pj" '@sveltejs/kit'; then fw="sveltekit";  port=5173
    elif _init_pkg_has "$pj" 'vitepress';     then fw="vitepress";  port=5173
    elif _init_pkg_has "$pj" 'nuxt';          then fw="nuxt";       port=3000
    elif _init_pkg_has "$pj" 'astro';         then fw="astro";      port=4321
    elif _init_pkg_has "$pj" '@remix-run';    then fw="remix";      port=3000
    elif _init_pkg_has "$pj" '@docusaurus';   then fw="docusaurus"; port=3000
    elif _init_pkg_has "$pj" 'gatsby';        then fw="gatsby";     port=8000; hostflag="-H 0.0.0.0"; portflag="-p"; pref="develop"
    elif _init_pkg_has "$pj" 'next';          then fw="next";       port=3000; hostflag="-H 0.0.0.0"; portflag="-p"
    elif _init_pkg_has "$pj" 'vite';          then fw="vite";       port=5173
    fi

    local script="" s
    for s in "$pref" dev develop serve start; do
      if _init_has_script "$pj" "$s"; then script="$s"; break; fi
    done
    [ -z "$script" ] && script="$pref"

    # honor a host/port the dev script already sets, rather than fighting it
    local sval ep
    sval="$(_init_json_str "$pj" "$script")"
    ep="$(_init_port_from "$sval")"; [ -n "$ep" ] && port="$ep"
    ports="$port"

    local inst run_script
    case "$pm" in
      npm)  inst="npm install";  run_script="npm run $script" ;;
      pnpm) inst="pnpm install"; run_script="pnpm run $script" ;;
      yarn) inst="yarn install"; run_script="yarn $script" ;;
      bun)  inst="bun install";  run_script="bun run $script" ;;
    esac
    case "$sval" in
      *0.0.0.0*|*--host*|*-H\ *)
        run_cmd="$inst && $run_script"
        note="the dev script already sets host/port; the egress allowlist is what's left - run 'sluice learn'." ;;
      *)
        run_cmd="$inst && $run_script -- $hostflag $portflag $port"
        note="npm/yarn registries are allowed; add runtime CDNs/APIs or run 'sluice learn'." ;;
    esac
    detected="node/$pm${fw:+ ($fw)}"

  elif [ -f "$dir/requirements.txt" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/Pipfile" ]; then
    # python
    stack="python"; allow="pypi.org files.pythonhosted.org"
    local pyver="3.12" v
    if [ -f "$dir/.python-version" ]; then
      v="$(grep -oE '3\.(11|12|13)' "$dir/.python-version" 2>/dev/null | head -1 || true)"; [ -n "$v" ] && pyver="$v"
    elif [ -f "$dir/pyproject.toml" ]; then
      v="$(grep -oE 'requires-python[^0-9]*3\.(11|12|13)' "$dir/pyproject.toml" 2>/dev/null | grep -oE '3\.(11|12|13)' | head -1 || true)"; [ -n "$v" ] && pyver="$v"
    fi
    local px="${pyver#3.}"
    extra_pkgs="python-$pyver py3.$px-pip"
    local pm="pip"
    if   [ -f "$dir/uv.lock" ]; then pm="uv"; extra_pkgs="$extra_pkgs uv"
    elif [ -f "$dir/poetry.lock" ] || _init_py_has 'tool\.poetry'; then pm="poetry"; extra_pkgs="$extra_pkgs poetry"
    elif [ -f "$dir/Pipfile" ]; then pm="pipenv"; setup="pip install --user pipenv"   # baked at build (free egress); no reliable Wolfi apk
    fi

    local entry="" f
    for f in app.py main.py server.py wsgi.py asgi.py run.py __main__.py; do
      [ -f "$dir/$f" ] && { entry="$f"; break; }
    done
    local mod="${entry%.py}"; [ -z "$mod" ] && mod="app"

    local fw="" fwcmd=""
    if   [ -f "$dir/manage.py" ] || _init_py_has 'django'; then fw="django"; fwcmd="python manage.py runserver 0.0.0.0:8000"; ports="8000"
    elif _init_py_has 'fastapi' || _init_py_has 'uvicorn';  then fw="fastapi"; fwcmd="uvicorn $mod:app --host 0.0.0.0 --port 8000"; ports="8000"
    elif _init_py_has 'flask';     then fw="flask";     fwcmd="flask --app $mod run --host 0.0.0.0 --port 5000"; ports="5000"
    elif _init_py_has 'streamlit'; then fw="streamlit"; fwcmd="streamlit run ${entry:-app.py} --server.address 0.0.0.0 --server.port 8501"; ports="8501"
    elif _init_py_has 'gradio';    then fw="gradio";    fwcmd="python ${entry:-app.py}"; ports="7860"; note="gradio must bind 0.0.0.0: launch(server_name='0.0.0.0', server_port=7860)."
    else fwcmd="python ${entry:-app.py}"; ports=""; note="SET YOUR ENTRY COMMAND - 'python ${entry:-app.py}' is a guess."
    fi

    local inst_target=""
    if   [ -f "$dir/requirements.txt" ]; then inst_target="-r requirements.txt"
    elif [ -f "$dir/pyproject.toml" ];   then inst_target="."
    fi
    case "$pm" in
      pip)
        if [ -f "$dir/requirements.txt" ]; then
          # F2: install deps at build (free egress, into ~/.local) so the runtime needs no pypi.
          prefetch_files="requirements.txt"; prefetch_cmd="export PATH=\"\$HOME/.local/bin:\$PATH\"; pip install --user -r requirements.txt"
          run_cmd="export PATH=\"\$HOME/.local/bin:\$PATH\"; $fwcmd"; allow=""
        elif [ -n "$inst_target" ]; then run_cmd="export PATH=\"\$HOME/.local/bin:\$PATH\"; pip install --user $inst_target && $fwcmd"
        else                             run_cmd="export PATH=\"\$HOME/.local/bin:\$PATH\"; $fwcmd"; fi ;;
      pipenv) run_cmd="export PATH=\"\$HOME/.local/bin:\$PATH\"; pipenv install && pipenv run $fwcmd" ;;
      poetry) run_cmd="poetry install && poetry run $fwcmd" ;;
      uv)     run_cmd="uv sync && uv run $fwcmd" ;;
    esac
    detected="python-$pyver/$pm${fw:+ ($fw)}"

  elif [ -f "$dir/deno.json" ] || [ -f "$dir/deno.jsonc" ]; then
    # deno
    stack="deno"; extra_pkgs="deno"
    allow="deno.land jsr.io registry.npmjs.org esm.sh cdn.jsdelivr.net"
    local dj="$dir/deno.json"; [ -f "$dj" ] || dj="$dir/deno.jsonc"
    if   _init_has_script "$dj" 'dev';   then run_cmd="deno task dev"
    elif _init_has_script "$dj" 'start'; then run_cmd="deno task start"
    else run_cmd="deno run -A main.ts"; fi
    ports=""; note="set SLUICE_PORTS to the port your server binds (Fresh defaults to 8000)."
    detected="deno"

  elif [ -f "$dir/Gemfile" ]; then
    # ruby (best-effort)
    # -dev + build-base + linux-headers so native-extension gems (puma/nokogiri/...) compile.
    stack="ruby"; extra_pkgs="ruby-3.3 ruby-3.3-dev build-base linux-headers"; detected="ruby-3.3"
    setup="mkdir -p \"\$HOME/.local/bin\" \"\$HOME/.gem/ruby\" && gem install --no-document --bindir \"\$HOME/.local/bin\" --install-dir \"\$HOME/.gem/ruby\" bundler"
    local rb="export GEM_HOME=\"\$HOME/.gem/ruby\"; export PATH=\"\$HOME/.local/bin:\$PATH\""
    local _rbserve _rails=""
    if grep -qE "gem ['\"]rails['\"]" "$dir/Gemfile" 2>/dev/null || [ -f "$dir/config/application.rb" ]; then _rails=1; fi
    if [ -n "$_rails" ]; then
      ports="3000"; _rbserve="bundle exec rails server -b 0.0.0.0 -p 3000"
    else
      local rbentry="app.rb"; [ -f "$dir/main.rb" ] && rbentry="main.rb"
      _rbserve="ruby $rbentry"; note="ruby is best-effort - set SLUICE_RUN_CMD/SLUICE_PORTS for your app."
    fi
    if [ -f "$dir/Gemfile.lock" ]; then
      # F2: install gems at build (free egress, into GEM_HOME) so the runtime needs no rubygems.
      prefetch_files="Gemfile Gemfile.lock"; prefetch_cmd="$rb; bundle install"; allow=""
      run_cmd="$rb; $_rbserve"; detected="ruby-3.3 (prefetched)"
    else
      allow="rubygems.org index.rubygems.org"; run_cmd="$rb; bundle install && $_rbserve"
    fi

  elif [ -f "$dir/Cargo.toml" ]; then
    # build-base provides the C linker (cc/ld) that rustc needs to link any binary.
    stack="rust"; detected="rust"; extra_pkgs="rust build-base"
    if [ -f "$dir/Cargo.lock" ]; then
      # F2: fetch crates at build (free egress) so the runtime needs no crates.io.
      prefetch_files="Cargo.toml Cargo.lock"; prefetch_cmd="cargo fetch"; run_cmd="cargo run --offline"; allow=""
      detected="rust (prefetched)"; note="deps are fetched at build (cargo fetch); runtime egress needs no crates.io. Edit Cargo.lock -> rebuild."
    else
      allow="static.crates.io index.crates.io"; run_cmd="cargo run"
    fi
  elif [ -f "$dir/go.mod" ]; then
    stack="go"; detected="go"; extra_pkgs="go"
    if [ -f "$dir/go.sum" ]; then
      # F2: download modules at build (free egress) so the runtime needs no go proxy.
      prefetch_files="go.mod go.sum"; prefetch_cmd="go mod download"; run_cmd="GOPROXY=off go run ."; allow=""
      detected="go (prefetched)"; note="deps are fetched at build (go mod download); runtime egress needs no go proxy. Edit go.sum -> rebuild."
    else
      allow="proxy.golang.org sum.golang.org"; run_cmd="go run ."
    fi

  elif [ -f "$dir/pom.xml" ] || [ -f "$dir/build.gradle" ] || [ -f "$dir/build.gradle.kts" ]; then
    # java/kotlin (best-effort): JDK + build tool; Spring Boot gets a server run cmd + port.
    stack="java"; allow="repo.maven.apache.org repo1.maven.org"
    local spring=""
    grep -qiE 'spring-boot' "$dir/pom.xml" "$dir/build.gradle" "$dir/build.gradle.kts" 2>/dev/null && { spring=1; ports="8080"; }
    if [ -f "$dir/pom.xml" ]; then
      extra_pkgs="openjdk-21 maven"
      if [ -n "$spring" ]; then run_cmd="mvn -q spring-boot:run"
      else run_cmd="mvn -q compile exec:java"; note="java/maven is best-effort - set SLUICE_RUN_CMD for your app."; fi
      detected="java/maven${spring:+ (spring-boot)}"
    else
      extra_pkgs="openjdk-21 gradle"; allow="$allow plugins.gradle.org services.gradle.org"
      local gw="gradle"; [ -f "$dir/gradlew" ] && gw="./gradlew"
      if [ -n "$spring" ]; then run_cmd="$gw bootRun"
      else run_cmd="$gw run"; note="java/gradle is best-effort - set SLUICE_RUN_CMD for your app."; fi
      detected="java/gradle${spring:+ (spring-boot)}"
    fi

  elif [ -f "$dir/composer.json" ]; then
    # php (best-effort): laravel gets artisan serve, else the built-in server.
    stack="php"; extra_pkgs="php composer"; allow="repo.packagist.org packagist.org"; ports="8000"
    if [ -f "$dir/artisan" ]; then
      run_cmd="composer install && php artisan serve --host 0.0.0.0 --port 8000"; detected="php/laravel"
    else
      run_cmd="composer install && php -S 0.0.0.0:8000"; detected="php"
      note="php is best-effort - set SLUICE_RUN_CMD/SLUICE_PORTS for your app."
    fi

  elif [ -n "$(ls "$dir"/*.csproj "$dir"/*.sln 2>/dev/null)" ]; then
    # .NET (best-effort): dotnet run, bound to 0.0.0.0 via the ASP.NET urls flag.
    stack="dotnet"; extra_pkgs="dotnet-sdk"; allow="api.nuget.org www.nuget.org"; ports="8080"
    run_cmd="dotnet run --urls http://0.0.0.0:8080"; detected="dotnet"
    note="dotnet is best-effort - confirm the port your app binds (ASPNETCORE_URLS)."

  elif [ -f "$dir/mix.exs" ]; then
    # elixir (best-effort): phoenix gets phx.server + 4000.
    stack="elixir"; extra_pkgs="elixir"; allow="repo.hex.pm builds.hex.pm"
    if grep -qiE 'phoenix' "$dir/mix.exs" 2>/dev/null; then
      ports="4000"; run_cmd="mix deps.get && mix phx.server"; detected="elixir/phoenix"
    else
      run_cmd="mix deps.get && mix run --no-halt"; detected="elixir"
      note="elixir is best-effort - set SLUICE_RUN_CMD/SLUICE_PORTS for your app."
    fi

  elif [ -f "$dir/pubspec.yaml" ]; then
    # dart (best-effort).
    stack="dart"; extra_pkgs="dart"; allow="pub.dev pub.dartlang.org"
    run_cmd="dart pub get && dart run"; detected="dart"
    note="dart is best-effort - set SLUICE_RUN_CMD/SLUICE_PORTS for your app."
  fi

  if [ "$stack" = generic ]; then
    local _grc
    if _grc="$(_init_runcmd_from_files)"; then
      run_cmd="$_grc"
      case "$_grc" in "make "*) extra_pkgs="make" ;; "just "*) extra_pkgs="just" ;; esac
      note="run command taken from a declared Procfile/Makefile/justfile target - add SLUICE_EXTRA_PKGS for your toolchain."
    else
      note="no known stack detected - set SLUICE_RUN_CMD and SLUICE_EXTRA_PKGS for your toolchain (or re-run from your project's root)."
    fi
  fi

  # secondary manifests (polyglot / monorepo): flag them, don't try to merge stacks
  local others=""
  [ "$stack" != node ]   && [ -f "$pj" ]             && others="$others node"
  [ "$stack" != python ] && { [ -f "$dir/requirements.txt" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/Pipfile" ]; } && others="$others python"
  [ "$stack" != ruby ]   && [ -f "$dir/Gemfile" ]    && others="$others ruby"
  [ "$stack" != go ]     && [ -f "$dir/go.mod" ]     && others="$others go"
  [ "$stack" != rust ]   && [ -f "$dir/Cargo.toml" ] && others="$others rust"
  [ "$stack" != java ]   && { [ -f "$dir/pom.xml" ] || [ -f "$dir/build.gradle" ] || [ -f "$dir/build.gradle.kts" ]; } && others="$others java"
  [ "$stack" != php ]    && [ -f "$dir/composer.json" ] && others="$others php"
  [ "$stack" != dotnet ] && [ -n "$(ls "$dir"/*.csproj "$dir"/*.sln 2>/dev/null)" ] && others="$others dotnet"
  [ -n "$others" ] && note2="also saw manifests for:$others - this config targets '$stack'; init each service in its own dir."

  # --update: refresh the detected fields, but keep the user's allowlist + any keys init doesn't manage
  # (SLUICE_ENV, hardening knobs, SLUICE_NAME, ...). Write to a temp, show a diff, confirm, then swap.
  local preserved_extra="" out="$cfg" _ea="" _a=""
  if [ "$update" -eq 1 ]; then
    _ea="$(grep -E '^SLUICE_ALLOW_DOMAINS=' "$cfg" 2>/dev/null | head -1 | sed -E 's/^SLUICE_ALLOW_DOMAINS=//; s/[[:space:]]+#.*$//; s/^"//; s/"$//')"
    [ -n "$_ea" ] && allow="$_ea"                          # keep the user's allowlist, not the detected base
    preserved_extra="$(grep -E '^SLUICE_[A-Z_]+=' "$cfg" 2>/dev/null | grep -vE '^SLUICE_(EXTRA_PKGS|EXTRA_NPM|SETUP_CMDS|PORTS|RUN_CMD|ALLOW_DOMAINS)=' || true)"
    out="$(mktemp)"
  fi

  {
    echo "# sluice config - scaffolded by 'sluice init' (detected: $detected)."
    echo "# Review the values, then run 'sluice' (or 'sluice learn' to discover the egress allowlist)."
    [ -n "$note" ]  && echo "# NOTE: $note"
    [ -n "$note2" ] && echo "# ALSO: $note2"
    echo ""
    [ -n "$extra_pkgs" ] && echo "SLUICE_EXTRA_PKGS=$(_init_q "$extra_pkgs")"
    [ -n "$extra_npm" ]  && echo "SLUICE_EXTRA_NPM=$(_init_q "$extra_npm")"
    [ -n "$setup" ]      && echo "SLUICE_SETUP_CMDS=$(_init_q "$setup")   # build-time, free egress, before the firewall"
    [ -n "$prefetch_files" ] && echo "SLUICE_PREFETCH_FILES=$(_init_q "$prefetch_files")   # manifests copied into the build for the prefetch"
    [ -n "$prefetch_cmd" ]   && echo "SLUICE_PREFETCH_CMD=$(_init_q "$prefetch_cmd")   # fetch deps at build (free egress) so runtime egress can drop the registry"
    echo "SLUICE_PORTS=$(_init_q "$ports")            # ports to publish (the app MUST bind 0.0.0.0)"
    echo "SLUICE_RUN_CMD=$(_init_q "$run_cmd")"
    echo "SLUICE_ALLOW_DOMAINS=$(_init_q "$allow")    # runtime egress hosts (or run 'sluice learn')"
    echo ""
    echo "# Hardening (opt-in - uncomment to enable; see THREAT_MODEL.md):"
    echo "# SLUICE_SECCOMP=hardened       # tighter syscall filter (>= engine default); 'browser' for Chromium/Playwright"
    echo "# SLUICE_READONLY_ROOT=1        # immutable rootfs (tmpfs + anon-volume the writable paths)"
    echo "# SLUICE_WORKSPACE=overlay      # mount the repo read-only; the box edits a copy (sluice diff | apply)"
    echo "# SLUICE_BUMP_DOMAINS=\"\"        # decrypt + inspect request URLs on these hosts (scoped TLS interception)"
    [ -n "$preserved_extra" ] && { echo ""; echo "# preserved from your previous config:"; printf '%s\n' "$preserved_extra"; }
  } > "$out"

  if [ "$update" -eq 1 ]; then
    if diff "$cfg" "$out" >/dev/null 2>&1; then
      rm -f "$out"; echo "[sluice] $cfg already matches detection - nothing to update."; return 0
    fi
    echo "[sluice] sluice init --update - proposed changes:"
    diff -u "$cfg" "$out" 2>/dev/null | sed 's/^/    /' || true
    if [ -t 0 ] && [ -t 1 ]; then
      printf '[sluice] apply? [y/N] '; read -r _a || _a=n
      case "$_a" in [yY]|[yY][eE][sS]) ;; *) rm -f "$out"; echo "[sluice] left $cfg unchanged."; return 0 ;; esac
    elif [ "${SLUICE_YES:-}" != 1 ]; then
      rm -f "$out"; echo "[sluice] non-interactive: re-run with SLUICE_YES=1 to apply these changes."; return 0
    fi
    mv "$out" "$cfg"; echo "[sluice] updated $cfg (allowlist + non-detected keys preserved)"; return 0
  fi

  echo "[sluice] detected: $detected"
  echo "[sluice] wrote $cfg"
  [ -n "$note2" ] && echo "[sluice] note: $note2"
  [ -n "${SLUICE_INIT_QUIET:-}" ] || echo "[sluice] next: review it, then 'sluice'  (or 'sluice learn' to fill the allowlist)."
}
if [ "${1:-}" = init ]; then banner; shift; cmd_init "$@"; exit 0; fi

# info commands: no config/engine/banner.
case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  -v|--version)   printf 'sluice %s\n' "$(sluice_version)"; exit 0 ;;
  version)        cmd_version "${2:-}"; exit 0 ;;
esac

# locate the project by walking cwd upward for sluice.config.sh
