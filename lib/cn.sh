# lib/cn.sh — China-facing latency helpers.
# Intentionally dependency-light: shells out to public tools rather than
# wiring up CN-based servers ourselves.
# shellcheck shell=bash

cfcn_cn() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    ping)
      local host="${1:?usage: cn ping <host>}"
      cfcn_step "Reachability from various observation points: $host"
      # Local ping as a baseline.
      cfcn_info "local (from your machine):"
      if command -v ping >/dev/null 2>&1; then
        ping -c 3 -W 2 "$host" 2>&1 | tail -4 | sed 's/^/    /'
      fi
      echo
      cfcn_tip "For CN ISP observation points, use a public monitor:"
      cfcn_tip "  - https://www.itdog.cn/ping/$host"
      cfcn_tip "  - https://ping.chinaz.com/$host"
      cfcn_tip "These probe from China Telecom/Unicom/Mobile nationwide and"
      cfcn_tip "are the quickest way to confirm your site is reachable from CN."
      ;;
    trace)
      local host="${1:?usage: cn trace <host>}"
      cfcn_step "Traceroute: $host"
      if command -v mtr >/dev/null 2>&1; then
        mtr -rw -c 10 "$host"
      elif command -v traceroute >/dev/null 2>&1; then
        traceroute "$host"
      else
        cfcn_warn "mtr/traceroute not installed"
      fi
      cfcn_tip "For CN-originating traces: https://tools.ipip.net/traceroute.php"
      ;;
    help|--help|"")
      cat <<'EOF'
cfcn cn — China-facing network checks.

  cn ping <host>    Local ping + pointers to public CN ping monitors.
  cn trace <host>   Local mtr/traceroute + pointer to ipip.net.
EOF
      ;;
    *) cfcn_err "unknown cn subcommand: $sub"; return 2 ;;
  esac
}
