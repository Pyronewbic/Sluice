derive_names() {
  slug="$(printf '%s' "${SLUICE_NAME:-$(basename "$PROJECT_DIR")}" | tr '[:upper:]' '[:lower:]' | tr -C 'a-z0-9' '-')"
  tag="sluice-$slug"; container="$tag"
}

# Always-on egress hosts (registries + GitHub); core/entrypoint.sh keeps its own in-container copy.
base_domains() { printf '%s' "github.com api.github.com codeload.github.com objects.githubusercontent.com registry.npmjs.org registry.yarnpkg.com"; }

# Public suffixes where the registrable domain sits one label below the last two - common second-level
# ccTLDs + dev-platform hosts that show up in allowlists. Not the full PSL (that'd be vendored data);
# the _collapsible guard makes an unlisted multi-part suffix fail "don't offer the wildcard", not over-allow.
# ccTLD second-levels + flat app/dev platforms + cloud storage at its true (deeper) suffix, so a
# multi-tenant host like a.s3.amazonaws.com collapses to a.s3... not the tenant-shared apex.
_PUBLIC_SUFFIXES="co.uk org.uk gov.uk ac.uk me.uk net.uk com.au net.au org.au gov.au edu.au co.nz net.nz org.nz co.jp ne.jp or.jp co.kr co.in co.za com.br com.cn com.mx com.sg com.tr github.io gitlab.io pages.dev workers.dev r2.dev vercel.app netlify.app web.app firebaseapp.com herokuapp.com azurewebsites.net cloudfront.net s3.amazonaws.com blob.core.windows.net storage.googleapis.com"

# Registrable parent (eTLD+1) of a host, public-suffix aware: the label just below the longest matching
# suffix. Returns the host unchanged when it IS a suffix / has nothing below one, so `learn` never
# offers a `.wildcard` equal to a public suffix. Wildcards stay offered, never forced.
parent_of() {
  local host="$1" s head
  for s in $_PUBLIC_SUFFIXES; do
    case "$host" in
      "$s")  printf '%s\n' "$host"; return 0 ;;
      *.$s)  head="${host%.$s}"; printf '%s.%s\n' "${head##*.}" "$s"; return 0 ;;
    esac
  done
  printf '%s\n' "$host" | awk -F. 'NF>=2{print $(NF-1)"."$NF; next}{print}'
}

# True when collapsing to ".$1" is safe to offer: at least two labels AND not itself a public suffix.
_collapsible() {
  local p="$1" s
  case "$p" in *.*) ;; *) return 1 ;; esac
  for s in $_PUBLIC_SUFFIXES; do [ "$p" = "$s" ] && return 1; done
  return 0
}

# Hash of config + core (+ base image ref), baked as an image label; rebuild when it changes.
# SLUICE_ALLOW_DOMAINS is excluded - applied at runtime (SLUICE_RUNTIME_ALLOW), so an allowlist edit
# (e.g. `sluice learn`) needs no rebuild.
config_hash() {
  { printf 'base=%s\n' "${SLUICE_BASE_IMAGE:-}"; grep -vE '^[[:space:]]*SLUICE_ALLOW_DOMAINS=' "$PROJECT_CONFIG"; \
    find "$CORE" -type f | LC_ALL=C sort | while read -r f; do cat "$f"; done; \
    for f in ${SLUICE_PREFETCH_FILES:-}; do [ -f "$PROJECT_DIR/$f" ] && cat "$PROJECT_DIR/$f"; done; } \
    | shasum | awk '{print $1}' | cut -c1-12
}

# ps-filter (not `inspect .State.Running`) so it works on both docker and nerdctl - nerdctl's native
# inspect has no docker-style .State key. grep -qx pins the exact name (not the -audit sibling).
running() { "$RUNNER" ps --filter "name=$container" --filter status=running --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; }

# True when the HOST enforces SELinux (Fedora/RHEL/CentOS default). On such a host a bind mount is
# inaccessible to the box without a label, so sluice runs it label=disable (see the run paths).
selinux_enforcing() { [ -r /sys/fs/selinux/enforce ] && [ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" = 1 ]; }

# squid access log. Full by default (box-level audit: egress/doctor/learn); from _RCPT_OFFSET bytes
# when set, so the run-default egress receipt is scoped to just that run, not the box's whole boot.
_squid_log() {
  if [ -n "${_RCPT_OFFSET:-}" ]; then
    "$RUNNER" exec "${1:-$container}" sh -c "tail -c +$(( _RCPT_OFFSET + 1 )) /var/log/squid/access.log" 2>/dev/null
  else
    "$RUNNER" exec "${1:-$container}" cat /var/log/squid/access.log 2>/dev/null
  fi
}

# Hostnames the proxy BLOCKED (SNI for HTTPS, Host for HTTP), from the running container's log.
blocked_hosts() {
  _squid_log | awk '
    { sni="";
      for (i=1;i<=NF;i++) if ($i ~ /^ssl_sni=/) sni=substr($i,9);
      status=$3; url=$5;
      if (status !~ /NONE_NONE/ && status !~ /TCP_DENIED/ && status !~ /\/000/) next;
      host="";
      if (sni != "" && sni != "-") host=sni;
      else if (url ~ /^http:\/\//) { h=url; sub(/^http:\/\//,"",h); sub(/\/.*/,"",h); sub(/:.*/,"",h); host=h }
      if (host == "" || host ~ /^[0-9.]+$/) next;
      print host
    }' | sort -u
}

# Hostnames the proxy ALLOWED (reached). reached_hosts_raw = one line per request (for counts);
# reached_hosts = unique. Optional $1 = container (learn --audit opens egress, so every host logs as a success).
reached_hosts_raw() {
  _squid_log "$@" | awk '
    { sni="";
      for (i=1;i<=NF;i++) if ($i ~ /^ssl_sni=/) sni=substr($i,9);
      status=$3; url=$5;
      if (status ~ /NONE_NONE/ || status ~ /TCP_DENIED/ || status ~ /\/000/) next;
      host="";
      if (sni != "" && sni != "-") host=sni;
      else if (url ~ /^http:\/\//) { h=url; sub(/^http:\/\//,"",h); sub(/\/.*/,"",h); sub(/:.*/,"",h); host=h }
      if (host == "" || host ~ /^[0-9.]+$/) next;
      print host
    }'
}
reached_hosts()  { reached_hosts_raw "$@" | sort -u; }

# Per-host egress rows for the receipt + `sluice egress`: one awk pass over the (offset-aware) proxy
# log -> "<class>\t<host>\t<count>\t<bytes>". class=reached if the host ever got through, else blocked
# (reached-precedence wins on mixed lines); count = successes (reached) or denials (blocked); bytes =
# tx+rx. The example.* boot canary + already-allowlisted /000-race hosts are dropped (matches blocked_new).
egress_rows() {
  _squid_log "$@" | awk -v allow=" $(allowed_domains) " '
    # Is host h allowlisted? Exact match, or covered by a leading-dot wildcard (.x matches x + *.x),
    # mirroring squid dstdomain - so learn never re-proposes a host a `.domain` entry already covers.
    function allowed(h,   n,i,t,tl,toks) {
      if (index(allow, " " h " ")) return 1;
      n = split(allow, toks, " ");
      for (i=1;i<=n;i++) { t=toks[i]; if (substr(t,1,1)==".") { tl=length(t);
        if (h==substr(t,2) || (length(h)>tl && substr(h,length(h)-tl+1)==t)) return 1; } }
      return 0;
    }
    { sni=""; tx=0; rx=0;
      for (i=1;i<=NF;i++) {
        if      ($i ~ /^ssl_sni=/) sni=substr($i,9);
        else if ($i ~ /^tx=/)      tx=substr($i,4)+0;
        else if ($i ~ /^rx=/)      rx=substr($i,4)+0;
      }
      status=$3; url=$5; host="";
      if (sni != "" && sni != "-") host=sni;
      else if (url ~ /^http:\/\//) { h=url; sub(/^http:\/\//,"",h); sub(/\/.*/,"",h); sub(/:.*/,"",h); host=h }
      if (host == "" || host ~ /^[0-9.]+$/) next;
      bytes[host] += tx + rx; seen[host]=1;
      if (status ~ /NONE_NONE/ || status ~ /TCP_DENIED/ || status ~ /\/000/) deny[host]++; else succ[host]++;
    }
    END {
      for (h in seen) {
        if (h ~ /^example\.(com|net|org)$/) continue;
        if (succ[h] > 0)        printf "reached\t%s\t%d\t%d\n", h, succ[h], bytes[h];
        else if (!allowed(h))   printf "blocked\t%s\t%d\t%d\n", h, deny[h], bytes[h];
      }
    }'
}

# bytes -> human (B / KB / MB, one decimal for KB+).
_human_bytes() {
  awk -v b="${1:-0}" 'BEGIN{ if (b<1024) printf "%d B", b; else if (b<1048576) printf "%.1f KB", b/1024; else printf "%.1f MB", b/1048576 }'
}

# Total bytes the box SENT OUT to hosts it actually reached (tx=%>st, the upload/request side) - the
# exfil-relevant volume for the SLUICE_EGRESS_MAX_BYTES budget. Blocked requests never left the proxy,
# so they don't count. Offset-aware via _squid_log (scoped to the run for the receipt).
egress_tx_total() {
  _squid_log "$@" | awk '
    { tx=0; status=$3;
      if (status ~ /NONE_NONE/ || status ~ /TCP_DENIED/ || status ~ /\/000/) next;   # blocked: did not leave
      for (i=1;i<=NF;i++) if ($i ~ /^tx=/) tx=substr($i,4)+0;
      total += tx;
    } END { print total+0 }'
}

# The proxy-log byte offset captured at the start of the last `sluice` run (written to /run by the run
# arms). Lets `sluice learn` scope to that run instead of the whole boot; empty if no run / box rebooted.
last_run_offset() { "$RUNNER" exec "$container" cat /run/sluice-run-offset 2>/dev/null | tr -dc 0-9; }
mark_run_start()  { "$RUNNER" exec "$container" sh -c 'wc -c < /var/log/squid/access.log | tr -dc 0-9 > /run/sluice-run-offset' 2>/dev/null || true; }

# This project's effective egress allowlist: config domains + the always-on base.
allowed_domains() { printf '%s %s' "${SLUICE_ALLOW_DOMAINS:-}" "$(base_domains)"; }

# True if a host is a known shared/public endpoint an attacker could also WRITE to - so data can be
# laundered out through it even though it's allowlisted (THREAT_MODEL "allowed-host laundering"; we
# splice, never decrypt). Heuristic + non-exhaustive; doctor nudges, never blocks.
laundering_host() {
  case "$1" in
    *s3.amazonaws.com|*.s3.*.amazonaws.com|storage.googleapis.com|*.blob.core.windows.net|*.r2.cloudflarestorage.com|*.digitaloceanspaces.com) return 0 ;;
    gist.github.com|gist.githubusercontent.com|*pastebin.com|paste.*|transfer.sh|0x0.st|file.io|*.tmpfiles.org) return 0 ;;
    webhook.site|*.ngrok.io|*.ngrok-free.app|hooks.slack.com|*.requestbin.com|*.pipedream.net) return 0 ;;
    api.openai.com|api.anthropic.com|generativelanguage.googleapis.com|api.cohere.ai) return 0 ;;
  esac
  return 1
}

# True if $host is on the baked DoH/DoT denylist (core/doh-endpoints.txt, the single source squid
# also reads). dstdomain semantics: a leading-dot entry matches the domain + subdomains; else exact.
doh_listed() {
  local host="$1" entry
  [ -f "$CORE/doh-endpoints.txt" ] || return 1
  while IFS= read -r entry; do
    case "$entry" in ''|\#*) continue ;; esac
    case "$entry" in
      .*) case ".$host" in *"$entry") return 0 ;; esac ;;
      *)  [ "$host" = "$entry" ] && return 0 ;;
    esac
  done < "$CORE/doh-endpoints.txt"
  return 1
}

# Blocked hosts NOT already allowed - the genuinely-missing ones. Drops the transient
# startup-race /000 on allowlisted hosts (e.g. registry.npmjs.org), so it never proposes them.
blocked_new() {
  local cur h
  cur=" $(allowed_domains) "
  blocked_hosts 2>/dev/null | while IFS= read -r h; do
    [ -n "$h" ] || continue
    case "$h" in example.com|example.net|example.org) continue;; esac   # boot deny-canary, not an app host
    case "$cur" in *" $h "*) ;; *) printf '%s\n' "$h";; esac
  done
}

# Count of genuinely-denied hosts for a running box, WITHOUT sourcing its config (for `ls --egress`).
# Reuses blocked_new wholesale: a subshell overrides the two globals it reads - $container (which
# box's log to exec) and $SLUICE_ALLOW_DOMAINS (the box's live allowlist, read from the container).
# base_domains() is still added by allowed_domains(), so base hosts never count as blocked.
box_blocked_count() {
  local al
  al="$("$RUNNER" exec "$1" cat /etc/squid/allowlist.txt 2>/dev/null | tr '\n' ' ' || true)"
  ( container="$1"; SLUICE_ALLOW_DOMAINS="$al"; blocked_new 2>/dev/null | grep -c . ) || true
}

# `sluice egress [--json]`: the box's egress audit record (reached vs. blocked)
# reached_hosts = what the box actually reached; blocked_new = genuinely-denied hosts (not in the
# allowlist, and minus the transient startup-race noise doctor also filters). A control-plane feed.
