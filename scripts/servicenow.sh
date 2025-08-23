#!/usr/bin/env bash
set -euo pipefail
if [[ ${DEBUG:-false} == "true" ]]; then
  set -x
fi

# -----------------------
# Globals
# -----------------------
API_URL=""
ACTION=""
SNOW_INSTANCE=""
HMAC_TOKEN=""
BODY=""
CR_ID=""
TIMEOUT=""

# -----------------------
# Helpers
# -----------------------

log() {
  local level="$1"; shift
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $*"
}

error_exit() {
  log "ERROR" "$*"
  exit 1
}

set_output() {
  local key="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "${key}=${value}" >> "$GITHUB_OUTPUT"
  else
    echo "OUTPUT $key=$value"
  fi
}

# -----------------------
# Authentication
# -----------------------

build_auth_header() {
  echo "-H x-sn-hmac-signature-256:$HMAC_TOKEN"
}

# -----------------------
# API Caller
# -----------------------

call_api() {
  local method="$1"; shift
  local url="$1"; shift
  local data="${1:-}"

  local auth_header
  auth_header=$(build_auth_header)

  if [[ -n "$data" ]]; then
    curl -s -X "$method" \
      -H "Content-Type: application/json" \
      $auth_header \
      -d "$data" \
      "$url"
  else
    curl -s -X "$method" \
      -H "Content-Type: application/json" \
      $auth_header \
      "$url"
  fi
}

# -----------------------
# Actions
# -----------------------

create_cr() {
  [[ -z "$BODY" ]] && error_exit "Request body (-b) is required for create action"

  log "INFO" "Creating Change Request"
  response=$(call_api "POST" "$API_URL" "$BODY") || error_exit "Failed to call API"

  cr_id=$(echo "$response" | jq -r '.result.number // empty')
  [[ -z "$cr_id" ]] && error_exit "Failed to parse CR ID from response"

  log "INFO" "Created CR: $cr_id"
  set_output "cr_id" "$cr_id"
}

wait_for_approval() {
  [[ -z "$CR_ID" ]] && error_exit "CR ID (-c) is required for wait action"
  log "INFO" "Waiting for approval of CR: $CR_ID"

  local start_time=$(date +%s)
  while true; do
    response=$(call_api "GET" "$API_URL/$CR_ID") || error_exit "Failed to fetch CR"

    approval=$(echo "$response" | jq -r '.result.approval // empty')
    state=$(echo "$response" | jq -r '.result.state // empty')

    log "DEBUG" "State: $state | Approval: $approval"

    case "$approval" in
      approved) log "INFO" "CR Approved"; return 0 ;;
      rejected) error_exit "CR Rejected" ;;
    esac

    if [[ -n "$TIMEOUT" ]]; then
      local now=$(date +%s)
      local elapsed=$(( (now - start_time) / 60 ))
      if (( elapsed >= TIMEOUT )); then
        error_exit "Timed out after $TIMEOUT minutes"
      fi
    fi

    log "INFO" "Still pending, retrying in 30s..."
    sleep 30
  done
}

close_cr() {
  [[ -z "$CR_ID" ]] && error_exit "CR ID (-c) is required for close action"

  log "INFO" "Closing CR: $CR_ID"
  call_api "PATCH" "$API_URL/$CR_ID" '{
    "state": "closed",
    "close_code": "successful",
    "close_notes": "Closed via GitHub Actions"
  }' >/dev/null || error_exit "Failed to close CR"

  log "INFO" "Closed CR: $CR_ID"
}

# -----------------------
# CLI Options
# -----------------------

usage() {
  cat <<EOF
Usage: $0 -a <action> -i <instance> -t <hmac_token> [-b <body>] [-c <cr_id>] [-m <timeout_minutes>]

Options:
  -a    Action to perform (create | wait | close)
  -i    ServiceNow instance (e.g. dev198952.service-now.com)
  -t    HMAC token (x-sn-hmac-signature-256)
  -b    JSON body for creating CR (required for create)
  -c    Change Request ID (required for wait, close)
  -m    Timeout in minutes for wait (optional, default: indefinite)
  -h    Show this help message
EOF
  exit 1
}

while getopts ":a:i:t:b:c:m:h" opt; do
  case $opt in
    a) ACTION="$OPTARG" ;;
    i) SNOW_INSTANCE="$OPTARG" ;;
    t) HMAC_TOKEN="$OPTARG" ;;
    b) BODY="$OPTARG" ;;
    c) CR_ID="$OPTARG" ;;
    m) TIMEOUT="$OPTARG" ;;
    h) usage ;;
    \?) error_exit "Invalid option: -$OPTARG" ;;
    :) error_exit "Option -$OPTARG requires an argument" ;;
  esac
done

[[ -z "$ACTION" || -z "$SNOW_INSTANCE" || -z "$HMAC_TOKEN" ]] && usage

API_URL="https://${SNOW_INSTANCE}/api/sn_chg_rest/change"

case "$ACTION" in
  create) create_cr ;;
  wait) wait_for_approval ;;
  close) close_cr ;;
  *) usage ;;
esac
