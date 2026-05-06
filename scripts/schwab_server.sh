#!/usr/bin/env bash
# Schwab API Trader server wrapper.
# All data and execution calls go through the running FastAPI server.
# Usage: bash scripts/schwab_server.sh <subcommand> [args...]
#
# The server handles all Schwab OAuth complexity.
# Routines never call Schwab directly — they call this wrapper.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env"

# Load .env for local runs (cloud routines use process env vars instead)
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

SERVER="${SERVER_URL:-${SCHWAB_TRADER_DASHBOARD_URL:-http://localhost:8000}}"
API_KEY="${SCHWAB_TRADER_OPERATOR_API_KEY:-}"

# Bash array for the auth header — avoids word-splitting the header value.
# Usage: curl -fsS "${_AUTH[@]}" "$SERVER/..."
if [[ -n "$API_KEY" ]]; then
    _AUTH=(-H "X-API-Key: $API_KEY")
else
    _AUTH=()
fi

# Verify server is reachable before any call
_check_server() {
    if ! curl -fsS --max-time 5 "$SERVER/health" > /dev/null 2>&1; then
        echo "ERROR: Server not reachable at $SERVER" >&2
        echo "Start the server with: ./start.sh" >&2
        exit 2
    fi
}

cmd="${1:-}"
shift || true

case "$cmd" in
    # ── Portfolio / account ─────────────────────────────────────────────────
    accounts)
        _check_server
        curl -fsS "${_AUTH[@]}" "$SERVER/api/v1/schwab/accounts"
        ;;

    positions)
        # Returns positions embedded in the accounts response
        _check_server
        curl -fsS "${_AUTH[@]}" "$SERVER/api/v1/schwab/accounts" | python3 -c "
import json, sys
data = json.load(sys.stdin)
accounts = data if isinstance(data, list) else [data]
for acct in accounts:
    positions = acct.get('securitiesAccount', {}).get('positions', [])
    print(json.dumps(positions, indent=2))
"
        ;;

    quotes)
        # Usage: quotes AAPL NVDA AMD ...
        _check_server
        symbols="${*:?usage: quotes SYM1 SYM2 ...}"
        sym_param=$(echo "$symbols" | tr ' ' ',')
        curl -fsS "${_AUTH[@]}" "$SERVER/api/v1/schwab/quotes?symbols=$sym_param"
        ;;

    orders)
        # Usage: orders [days]  (default: last 7 days)
        _check_server
        days="${1:-7}"
        from=$(python3 -c "from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc)-timedelta(days=$days)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
        to=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
        curl -fsS "${_AUTH[@]}" "$SERVER/api/v1/schwab/orders?fromEnteredTime=${from}&toEnteredTime=${to}"
        ;;

    # ── Research ─────────────────────────────────────────────────────────────
    news)
        # Usage: news AAPL NVDA  (space-separated symbols, optional)
        _check_server
        if [[ $# -gt 0 ]]; then
            sym_param=$(echo "$*" | tr ' ' ',')
            curl -fsS "${_AUTH[@]}" "$SERVER/api/v1/news/feed?symbols=$sym_param"
        else
            curl -fsS "${_AUTH[@]}" "$SERVER/api/v1/news/feed"
        fi
        ;;

    earnings)
        _check_server
        curl -fsS "${_AUTH[@]}" "$SERVER/api/v1/earnings/calendar"
        ;;

    sectors)
        # Usage: sectors [SYM1 SYM2 ...]  (defaults to major sector ETFs)
        _check_server
        if [[ $# -gt 0 ]]; then
            sym_param=$(echo "$*" | tr ' ' ',')
        else
            sym_param="XLK,XLF,XLE,XLV,XLI,XLY,XLP,XLU,XLB,XLRE,XLC"
        fi
        curl -fsS "${_AUTH[@]}" "$SERVER/api/v1/earnings/sectors?symbols=$sym_param"
        ;;

    # ── Performance ──────────────────────────────────────────────────────────
    performance)
        _check_server
        curl -fsS "${_AUTH[@]}" "$SERVER/api/v1/performance/history?days=${1:-30}"
        ;;

    # ── Agent actions ────────────────────────────────────────────────────────
    run-check)
        # Trigger the portfolio health check (flags down positions, earnings risk, etc.)
        _check_server
        curl -fsS "${_AUTH[@]}" -X POST "$SERVER/api/v1/agent/run-check" \
            -H "Content-Type: application/json"
        ;;

    run-buy-scan)
        # Trigger the buy scan — screens watchlist, calls Claude, sends SMS/email proposals
        _check_server
        curl -fsS "${_AUTH[@]}" -X POST "$SERVER/api/v1/agent/run-buy-scan" \
            -H "Content-Type: application/json"
        ;;

    alerts)
        # List all stored alerts/proposals
        _check_server
        curl -fsS "${_AUTH[@]}" "$SERVER/api/v1/agent/alerts"
        ;;

    notify)
        # Usage: notify "message"  OR  notify urgent "message"
        # Routes SMS through the server — no Twilio creds needed in routine env
        _check_server
        URGENT="false"
        if [[ "${1:-}" == "urgent" ]]; then
            URGENT="true"
            shift
        fi
        MSG="${*:?usage: notify [urgent] <message>}"
        curl -fsS "${_AUTH[@]}" -X POST "$SERVER/api/v1/agent/notify" \
            -H "Content-Type: application/json" \
            -d "{\"message\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$MSG"), \"urgent\": $URGENT}"
        ;;

    email-summary)
        # Usage: email-summary "Subject" "Body text"
        # Sends an informational summary email (no approve/deny buttons).
        # Returns {"sent": true} on success, {"sent": false} if email not configured.
        _check_server
        SUBJECT="${1:?usage: email-summary <subject> <body>}"
        BODY="${2:?usage: email-summary <subject> <body>}"
        curl -fsS "${_AUTH[@]}" -X POST "$SERVER/api/v1/agent/email-summary" \
            -H "Content-Type: application/json" \
            -d "{\"subject\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$SUBJECT"), \
                 \"body\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$BODY")}"
        ;;

    # ── Health ───────────────────────────────────────────────────────────────
    health)
        curl -fsS "$SERVER/health"
        ;;

    # ── Email notification ───────────────────────────────────────────────────
    send-email)
        # Usage: send-email "Subject line" "Body text (can be multi-line)"
        _check_server
        SUBJECT="${1:?usage: send-email <subject> <body>}"
        BODY="${2:?usage: send-email <subject> <body>}"
        curl -fsS "${_AUTH[@]}" -X POST "$SERVER/api/v1/agent/send-email" \
            -H "Content-Type: application/json" \
            -d "{
              \"subject\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$SUBJECT"),
              \"body\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$BODY")
            }"
        ;;

    # ── Emergency order — crash/crisis ONLY ─────────────────────────────────
    emergency-order)
        # Usage: emergency-order BUY|SELL SYMBOL QUANTITY LIMIT_PRICE "REASONING"
        # Only use this when Claude has determined a genuine market crisis (crash-level event).
        # Normal trades are blocked by require_human_approval — this bypasses that gate.
        _check_server
        ACTION="${1:?usage: emergency-order BUY|SELL SYMBOL QUANTITY LIMIT_PRICE REASONING}"
        SYMBOL="${2:?missing SYMBOL}"
        QTY="${3:?missing QUANTITY}"
        PRICE="${4:?missing LIMIT_PRICE (use 0 for MARKET)}"
        REASONING="${5:?missing REASONING — required to document the crisis thesis}"
        ORDER_TYPE="LIMIT"
        LIMIT_ARG="\"limit_price\": $PRICE"
        if [[ "$PRICE" == "0" ]]; then
            ORDER_TYPE="MARKET"
            LIMIT_ARG="\"limit_price\": null"
        fi
        curl -fsS "${_AUTH[@]}" -X POST "$SERVER/api/v1/agent/direct-order" \
            -H "Content-Type: application/json" \
            -d "{
              \"symbol\": \"$SYMBOL\",
              \"action\": \"$ACTION\",
              \"quantity\": $QTY,
              \"order_type\": \"$ORDER_TYPE\",
              $LIMIT_ARG,
              \"reasoning\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$REASONING"),
              \"emergency\": true
            }"
        ;;

    ping)
        if curl -fsS --max-time 5 "$SERVER/health" > /dev/null 2>&1; then
            echo "Server is up at $SERVER"
        else
            echo "Server is DOWN at $SERVER" >&2
            exit 2
        fi
        ;;

    *)
        cat >&2 <<EOF
Usage: bash scripts/schwab_server.sh <subcommand> [args]

Subcommands:
  accounts              Full account + positions data
  positions             Positions only (parsed from accounts)
  quotes SYM1 SYM2...   Live quotes for one or more symbols
  orders                Open orders
  news [SYM1 SYM2...]   News feed (optionally filtered by symbols)
  earnings              Upcoming earnings calendar
  sectors               Sector performance data
  performance [days]    Performance history (default 30 days)
  run-check             Trigger portfolio health check agent
  run-buy-scan          Trigger buy scan agent (screens + proposes)
  alerts                List all stored alerts and proposals
  health                Raw health check response
  ping                  Human-readable server status check
  send-email            "Subject" "Body" — send a notification email via configured provider
  emergency-order       BUY|SELL SYMBOL QTY PRICE "REASON" — crash/crisis only, bypasses approval
EOF
        exit 1
        ;;
esac
echo
