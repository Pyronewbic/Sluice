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
    for f in ${SLUICE_PREFETCH_FILES:-}; do [ -f "$PROJECT_DIR/$f" ] && cat "$PROJECT_DIR/$f"; done; \
    printf 'pin=%s\n' "${SLUICE_PIN:-}"; \
    if [ "${SLUICE_PIN:-}" = 1 ] && [ -f "$PROJECT_DIR/sluice.pin" ]; then cat "$PROJECT_DIR/sluice.pin"; fi; } \
    | _sha256 | cut -c1-12
}

# ps-filter (not `inspect .State.Running`) so it works on both docker and nerdctl - nerdctl's native
# inspect has no docker-style .State key. grep -qx pins the exact name (not the -audit sibling).
running() { "$RUNNER" ps --filter "name=$container" --filter status=running --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; }

# True when the HOST enforces SELinux (Fedora/RHEL/CentOS default). On such a host a bind mount is
# inaccessible to the box without a label, so sluice runs it label=disable (see the run paths).
selinux_enforcing() { [ -r /sys/fs/selinux/enforce ] && [ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" = 1 ]; }

# Root-context maintenance execs (receipt/learn/apply) run as the container's root - NOT --user sluice.
# The image PATH must never let a uid-1000-writable dir (/home/sluice/.npm-global/bin) shadow a system
# tool here, or a planted ~/.npm-global/bin/tail runs as root. Force a clean system PATH on every such
# exec. Session execs (_exec_args) stay --user sluice and keep the full PATH for the workload's tools.
_ROOT_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
_root_exec() { "$RUNNER" exec -e "PATH=$_ROOT_PATH" "$@"; }

# True when the box's in-container audit log is actually READABLE. A uid-1000 workload can exhaust the
# pids cgroup so `<engine> exec` can't fork - _squid_log would then return empty (a FAILED read), which
# would misread as zero egress. Callers gate on this to record `unavailable` / fail the byte gate closed.
_audit_readable() { _root_exec "$container" true >/dev/null 2>&1; }

# squid access log. From _RCPT_OFFSET bytes when set (the run-scoped receipt); otherwise the last
# _SQUID_LOG_CAP bytes - a ceiling so an attacker can't inflate host CPU/IO by spamming the log and
# forcing an unbounded `cat | awk` on the box-level audit paths (egress/doctor/learn --all). 16 MiB
# holds far more than any real session; a truncated first line just gets skipped by the awk parsers.
_SQUID_LOG_CAP=16777216
_squid_log() {
  if [ -n "${_RCPT_OFFSET:-}" ]; then
    _root_exec "${1:-$container}" sh -c "tail -c +$(( _RCPT_OFFSET + 1 )) /var/log/squid/access.log" 2>/dev/null
  else
    _root_exec "${1:-$container}" sh -c "tail -c $_SQUID_LOG_CAP /var/log/squid/access.log" 2>/dev/null
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
      if (host !~ /^\.?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/) next;   # drop non-hostname chars: a raw SNI/Host carries $(),",ESC -> config-write RCE + terminal-escape injection
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
      if (host !~ /^\.?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/) next;   # drop non-hostname chars: a raw SNI/Host carries $(),",ESC -> config-write RCE + terminal-escape injection
      print host
    }'
}
reached_hosts()  { reached_hosts_raw "$@" | sort -u; }

# Denied requests whose target is a raw IPv4 literal (an IP CONNECT/URL has no hostname to filter, so
# the proxy denies it). The hostname ledgers skip numeric hosts (`learn` must never propose an IP), which
# made these probes invisible - count them instead. Offset-aware via _squid_log (run-scoped in the receipt).
denied_ip_requests() {
  _squid_log | awk '
    { sni=""; for (i=1;i<=NF;i++) if ($i ~ /^ssl_sni=/) sni=substr($i,9);
      status=$3; url=$5; host="";
      if (status !~ /NONE_NONE/ && status !~ /TCP_DENIED/ && status !~ /\/000/) next;
      if (sni != "" && sni != "-") host=sni;
      else if (url ~ /^http:\/\//) { h=url; sub(/^http:\/\//,"",h); sub(/\/.*/,"",h); sub(/:.*/,"",h); host=h }
      else { h=url; sub(/:[0-9]+$/,"",h); host=h }
      # Spelled out, not {3}: mawk builds without --re-interval never match a brace repeat.
      if (host ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) n++;
    } END { print n+0 }'
}

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
      if (host !~ /^\.?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/) next;   # drop non-hostname chars: a raw SNI/Host carries $(),",ESC -> config-write RCE + terminal-escape injection
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

# bytes -> human (B / KB / MB / GB / TB; one decimal KB-MB, two GB+). GB/TB matter: a bulk exfil that
# would print as "~5222.4 MB" reads clearly as "5.10 GB".
_human_bytes() {
  awk -v b="${1:-0}" 'BEGIN{
    if (b<1024) printf "%d B", b;
    else if (b<1048576) printf "%.1f KB", b/1024;
    else if (b<1073741824) printf "%.1f MB", b/1048576;
    else if (b<1099511627776) printf "%.2f GB", b/1073741824;
    else printf "%.2f TB", b/1099511627776 }'
}

# Byte threshold above which a single reached host is flagged "high volume" in the receipt - a bulk
# transfer that would otherwise blend into a normal allowlisted row. Default 1 GiB; SLUICE_EGRESS_FLAG_BYTES overrides.
_egress_flag_bytes() { local t="${SLUICE_EGRESS_FLAG_BYTES:-1073741824}"; case "$t" in ''|*[!0-9]*) t=1073741824 ;; esac; printf '%s' "$t"; }

# Total bytes the box SENT OUT to hosts it actually reached (tx=%>st, the upload/request side) - the
# exfil-relevant volume for the SLUICE_EGRESS_MAX_BYTES budget. Blocked requests never left the proxy,
# so they don't count. Offset-aware via _squid_log (scoped to the run for the receipt).
egress_tx_total() {
  _squid_log | awk '
    { tx=0; status=$3;
      if (status ~ /NONE_NONE/ || status ~ /TCP_DENIED/ || status ~ /\/000/) next;   # blocked: did not leave
      for (i=1;i<=NF;i++) if ($i ~ /^tx=/) tx=substr($i,4)+0;
      total += tx;
    } END { print total+0 }'
}

# Bytes SENT OUT keyed by reached host: "<host>\t<tx>". Same exfil-direction measure as egress_tx_total
# (tx only; blocked requests never left the proxy), grouped by host for the SLUICE_EGRESS_HOST_BUDGETS
# per-host gate. Offset-aware via _squid_log (scoped to the run for the receipt). Mirrors egress_rows'
# host + hostname-charset parsing.
egress_tx_by_host() {
  _squid_log | awk '
    { sni=""; tx=0; status=$3; url=$5;
      if (status ~ /NONE_NONE/ || status ~ /TCP_DENIED/ || status ~ /\/000/) next;   # blocked: did not leave
      for (i=1;i<=NF;i++) { if ($i ~ /^ssl_sni=/) sni=substr($i,9); else if ($i ~ /^tx=/) tx=substr($i,4)+0; }
      host="";
      if (sni != "" && sni != "-") host=sni;
      else if (url ~ /^http:\/\//) { h=url; sub(/^http:\/\//,"",h); sub(/\/.*/,"",h); sub(/:.*/,"",h); host=h }
      if (host == "" || host ~ /^[0-9.]+$/) next;
      if (host !~ /^\.?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/) next;   # drop non-hostname chars (SNI/Host can carry $(),",ESC)
      tot[host] += tx;
    }
    END { for (h in tot) printf "%s\t%d\n", h, tot[h] }'
}

# Resolve a host to its SLUICE_EGRESS_HOST_BUDGETS cap in bytes (empty = no budget for this host).
# Tokens are "host=bytes" (exact) or ".wildcard=bytes" (.x matches x + *.x, squid dstdomain style).
# Exact match wins outright; among wildcards the longest (most specific) wins. set -f so the unquoted
# split can't glob a value.
_host_budget_for() {
  local host="$1" tok thost tbytes bare best="" bestlen=-1
  set -f
  for tok in ${SLUICE_EGRESS_HOST_BUDGETS:-}; do
    case "$tok" in *=*) ;; *) continue ;; esac
    thost="${tok%%=*}"; tbytes="${tok#*=}"
    case "$tbytes" in ''|*[!0-9]*) continue ;; esac
    if [ "$thost" = "$host" ]; then best="$tbytes"; break; fi   # exact beats any wildcard
    case "$thost" in
      .*) bare="${thost#.}"
          if [ "$host" = "$bare" ] || case "$host" in *"$thost") true ;; *) false ;; esac; then
            [ "${#thost}" -gt "$bestlen" ] && { best="$tbytes"; bestlen="${#thost}"; }
          fi ;;
    esac
  done
  set +f
  printf '%s' "$best"
}

# Per-entry SLUICE_ALLOW_IPS accounting: read the OUTPUT chain's counters (the direct-egress jumps route
# through SLUICE-ALLOWIPS), emitting "<entry>\t<packets>\t<bytes>" per entry - the first visibility into
# the direct-IP escape hatch, which bypasses squid and was invisible to the receipt. Root-side iptables
# read (NET_ADMIN kept; /sbin on _ROOT_PATH). Empty read is gated by _audit_readable at the call site.
# Note: these count ATTEMPTED wire bytes (headers included; packets a budget DROP later ate are counted);
# entries on :80/:443 are dead (the NAT REDIRECT wins) and show 0.
allowips_rows() {
  _root_exec "$container" iptables -nvxL OUTPUT 2>/dev/null | awk '
    $3=="SLUICE-ALLOWIPS" {
      dst=$9; port="";
      for (i=10;i<=NF;i++) if ($i ~ /^dpt:/) port=substr($i,5);
      entry=(port=="") ? dst : dst":"port;
      printf "%s\t%d\t%d\n", entry, $1, $2;
    }'
}

# Firewall-dropped total: parse the OUTPUT chain's policy-DROP counter ("Chain OUTPUT (policy DROP N
# packets, M bytes)") - the first visibility into non-HTTP blocked egress attempts. Emits "<packets>\t<bytes>".
fw_dropped() {
  _root_exec "$container" iptables -nvxL OUTPUT 2>/dev/null | awk '
    /^Chain OUTPUT / {
      p=0; b=0;
      for (i=1;i<=NF;i++) { if ($i ~ /^packets,?$/) p=$(i-1); if ($i ~ /^bytes\)?$/) b=$(i-1); }
      printf "%d\t%d\n", p, b; exit;
    }'
}

# DNS query audit (SLUICE_DNS_AUDIT=1): read dnsmasq's query log and group by immediate parent domain,
# emitting "<parent>\t<queries>\t<unique_names>". A DNS tunnel concentrates MANY unique leftmost labels
# under one parent (exfil as DNS labels), so a high unique-name count per parent is the signal. Queried
# names are attacker-controlled bytes -> the same hostname charset gate as SNI (drops $(),",ESC). Reuses
# the _SQUID_LOG_CAP DoS ceiling. Empty read gated by _audit_readable at the call site.
dns_rows() {
  _root_exec "$container" sh -c "tail -c $_SQUID_LOG_CAP /var/log/squid/dns.log" 2>/dev/null | awk '
    /query\[/ {
      name="";
      for (i=1;i<=NF;i++) if ($i ~ /^query\[/) { name=$(i+1); break }
      if (name=="" || name !~ /^[A-Za-z0-9._-]+$/) next;   # non-hostname bytes: skip (RCE/escape guard)
      n=split(name, L, ".");
      if (n<=2) parent=name; else { parent=L[2]; for (j=3;j<=n;j++) parent=parent"."L[j] }
      cnt[parent]++;
      key=parent SUBSEP name;
      if (!(key in seen)) { seen[key]=1; uniq[parent]++ }
    }
    END { for (p in cnt) printf "%s\t%d\t%d\n", p, cnt[p], uniq[p] }'
}

# Packets the SLUICE_ALLOW_IPS shared budget DROP'd (SLUICE_ALLOW_IPS_MAX_BYTES exhausted mid-run). A
# non-zero count means the box hit the direct-IP cap during the run -> `sluice egress` fails the gate.
# Empty when the chain/budget isn't present (no SLUICE-ALLOWIPS DROP rule).
allowips_dropped() {
  _root_exec "$container" iptables -nvxL SLUICE-ALLOWIPS 2>/dev/null | awk '
    $3=="DROP" { print $1+0; found=1; exit } END { if (!found) print "" }'
}

# ",\"allow_ips\":[...]" (only when SLUICE_ALLOW_IPS is set) plus always-on drop accountability:
# ",\"fw_dropped\":{...},\"denied_ip_requests\":N". A raw-IP probe or non-HTTP attempt is recorded for
# every box, not only ones that configured a direct-IP lane.
_allowips_json_fields() {
  local TAB e p b aij="" first=1 aif="" fwd fp fb dip; TAB="$(printf '\t')"
  if [ -n "${SLUICE_ALLOW_IPS:-}" ]; then
    while IFS="$TAB" read -r e p b; do
      [ -n "$e" ] || continue
      [ "$first" = 1 ] && first=0 || aij="$aij,"
      aij="$aij{\"entry\":\"$(_json_esc "$e")\",\"packets\":${p:-0},\"bytes\":${b:-0}}"
    done <<EOF
$(allowips_rows 2>/dev/null || true)
EOF
    aif=",\"allow_ips\":[$aij]"
  fi
  fwd="$(fw_dropped 2>/dev/null || true)"; fp="${fwd%%"$TAB"*}"; fb="${fwd#*"$TAB"}"
  case "$fp" in ''|*[!0-9]*) fp=0 ;; esac
  case "$fb" in ''|*[!0-9]*) fb=0 ;; esac
  dip="$(denied_ip_requests 2>/dev/null || true)"; case "$dip" in ''|*[!0-9]*) dip=0 ;; esac
  printf '%s,"fw_dropped":{"packets":%s,"bytes":%s},"denied_ip_requests":%s' "$aif" "$fp" "$fb" "$dip"
}

# ",\"dns\":{...}" when SLUICE_DNS_AUDIT=1, else "". Sums dns_rows for totals + flags tunnel parents
# (unique names >= SLUICE_DNS_TUNNEL_THRESHOLD, default 500).
_dns_json_fields() {
  [ "${SLUICE_DNS_AUDIT:-}" = 1 ] || { printf ''; return 0; }
  local TAB p q u tq=0 tu=0 fl="" ffirst=1 thr; TAB="$(printf '\t')"
  thr="${SLUICE_DNS_TUNNEL_THRESHOLD:-500}"; case "$thr" in ''|*[!0-9]*) thr=500 ;; esac
  while IFS="$TAB" read -r p q u; do
    [ -n "$p" ] || continue
    tq=$((tq + q)); tu=$((tu + u))
    if [ "$u" -ge "$thr" ]; then
      [ "$ffirst" = 1 ] && ffirst=0 || fl="$fl,"
      fl="$fl{\"parent\":\"$(_json_esc "$p")\",\"unique\":$u}"
    fi
  done <<EOF
$(dns_rows 2>/dev/null || true)
EOF
  printf ',"dns":{"queries":%s,"unique":%s,"flagged":[%s]}' "$tq" "$tu" "$fl"
}

# The proxy-log byte offset captured at the start of the last `sluice` run (written to /run by the run
# arms). Lets `sluice learn` scope to that run instead of the whole boot; empty if no run / box rebooted.
# `|| true` on the cat: a missing offset file -> empty offset (callers' full-log fallback), never a
# pipefail that would abort the bare-assignment call sites (learn/doctor/ls) under set -e.
last_run_offset() { { _root_exec "$container" cat /run/sluice-run-offset 2>/dev/null || true; } | tr -dc 0-9; }
mark_run_start()  { _root_exec "$container" sh -c 'wc -c < /var/log/squid/access.log | tr -dc 0-9 > /run/sluice-run-offset' 2>/dev/null || true; }

# sha256 of stdin (hex only). Prefer coreutils sha256sum (Linux: Alpine, *-slim, most CI images have
# no perl-based `shasum`); fall back to `shasum -a 256` (macOS ships that, not sha256sum). Both are
# SHA-256, so the digest is identical whichever tool runs - a hard requirement for config_hash.
_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi 2>/dev/null | awk '{print $1}'; }

# Arm the at-exit egress receipt for a session: snapshot the proxy-log position so the receipt is
# scoped to THIS run (not the box's whole boot), mark the run start so a later `learn` can scope to it,
# and trap the receipt on EXIT (fires on normal exit, die, or Ctrl-C). Shared by run-default/shell/run.
arm_receipt() {
  _RCPT_OFFSET="$(_root_exec "$container" sh -c 'wc -c < /var/log/squid/access.log' 2>/dev/null | tr -dc 0-9)"
  mark_run_start
  trap show_egress_receipt EXIT
}

# This project's effective egress allowlist: config domains + the always-on base.
allowed_domains() { printf '%s %s' "${SLUICE_ALLOW_DOMAINS:-}" "$(base_domains)"; }

# Concrete launderer anchor hosts for the wildcard-cover check below (the case patterns stay the primary
# matcher for exact + leading-dot-subdomain entries). Anchors are the launderers a collapsible PARENT
# wildcard could cover - e.g. `.googleapis.com` covers storage.googleapis.com.
_LAUNDER_COVER="storage.googleapis.com generativelanguage.googleapis.com s3.amazonaws.com blob.core.windows.net r2.cloudflarestorage.com digitaloceanspaces.com gist.github.com raw.githubusercontent.com api.openai.com api.anthropic.com api.cohere.ai ampcode.com dashscope.aliyuncs.com dashscope-intl.aliyuncs.com api2.cursor.sh api5.cursor.sh catwalk.charm.land api-v2.plandex.ai"

# True if a host is a known shared/public endpoint an attacker could also WRITE to - so data can be
# laundered out through it even though it's allowlisted (THREAT_MODEL "allowed-host laundering"; we
# splice, never decrypt). Heuristic + non-exhaustive; doctor nudges, never blocks. $1 may be a leading-dot
# WILDCARD (what `sluice learn` writes): flagged if it IS/sits-under a launderer OR - like doh_listed -
# COVERS one (`.googleapis.com` covers storage.googleapis.com), so a parent-wildcard collapse can't slip
# a launderer past the gate / a forbid-laundering policy.
laundering_host() {
  local lh
  case "$1" in
    .*) for lh in $_LAUNDER_COVER; do case ".$lh" in *"$1") return 0 ;; esac; done ;;
  esac
  set -- "${1#.}"   # else match the bare host (a .host wildcard also covers the bare host)
  case "$1" in
    *s3.amazonaws.com|*.s3.*.amazonaws.com|storage.googleapis.com|*.blob.core.windows.net|*.r2.cloudflarestorage.com|*.digitaloceanspaces.com) return 0 ;;
    gist.github.com|gist.githubusercontent.com|raw.githubusercontent.com|*pastebin.com|paste.*|transfer.sh|0x0.st|file.io|*.tmpfiles.org) return 0 ;;
    webhook.site|*.ngrok.io|*.ngrok-free.app|hooks.slack.com|*.requestbin.com|*.pipedream.net) return 0 ;;
    api.openai.com|api.anthropic.com|generativelanguage.googleapis.com|api.cohere.ai) return 0 ;;
    ampcode.com|dashscope.aliyuncs.com|dashscope-intl.aliyuncs.com|api2.cursor.sh|api5.cursor.sh|*.api5.cursor.sh|catwalk.charm.land|api-v2.plandex.ai) return 0 ;;  # agent-provider model/stream hosts shipped presets allow (POST-capable)
  esac
  return 1
}

# True if $host is on the baked DoH/DoT denylist (core/doh-endpoints.txt, the single source squid
# also reads). dstdomain semantics: a leading-dot entry matches the domain + subdomains; else exact.
doh_listed() {
  # Match case-insensitively (squid dstdomain / dnsmasq are; the SNI regex accepts uppercase). $1 may be
  # a leading-dot WILDCARD. Reject when the candidate IS a DoH endpoint, sits UNDER a DoH wildcard, OR is
  # a wildcard that COVERS a DoH endpoint host - e.g. `.adguard.com` would re-allow the listed
  # dns.adguard.com. The denylist is lowercase.
  local cand ch entry eh
  cand="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"; ch="${cand#.}"
  [ -f "$CORE/doh-endpoints.txt" ] || return 1
  while IFS= read -r entry; do
    case "$entry" in ''|\#*) continue ;; esac
    eh="${entry#.}"
    case "$entry" in
      .*) case ".$ch" in *"$entry") return 0 ;; esac ;;   # candidate is, or sits under, a DoH wildcard
      *)  [ "$ch" = "$entry" ] && return 0 ;;              # candidate is the exact DoH host
    esac
    case "$cand" in .*) case ".$eh" in *"$cand") return 0 ;; esac ;; esac   # wildcard candidate covers it
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
# Fail-closed: a zero is only trusted after _audit_readable confirms the exec path still works; an
# unreadable box (e.g. pids exhausted) emits EMPTY (unknown) - ls renders ? / null, never a false 0.
box_blocked_count() {
  local al n
  al="$(_root_exec "$1" cat /etc/squid/allowlist.txt 2>/dev/null | tr '\n' ' ' || true)"
  n="$( ( container="$1"; SLUICE_ALLOW_DOMAINS="$al"; blocked_new 2>/dev/null | grep -c . ) || true )"
  [ "${n:-0}" -gt 0 ] || ( container="$1"; _audit_readable ) || return 0   # a 0 may be a FAILED read - confirm it
  printf '%s\n' "$n"
}

# `sluice egress [--json]`: the box's egress audit record (reached vs. blocked)
# reached_hosts = what the box actually reached; blocked_new = genuinely-denied hosts (not in the
# allowlist, and minus the transient startup-race noise doctor also filters). A control-plane feed.
