#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  test-github-app-dispatch.sh --client-id <id> --private-key <pem-path> [options]

Options:
  --owner <org>          GitHub owner/org (default: DystopianOS)
  --repo <repo>          Target repo for workflow dispatch (default: Dystopian-PKGBUILDS)
  --workflow <file>      Workflow file name (default: build_repo.yml)
  --ref <ref>            Git ref for workflow dispatch (default: main)
  --package <name>       Input package (default: dystopian-keyring)
  --channel <name>       Input channel (default: x86_64)
  --no-dispatch          Only mint token and verify repo access; skip dispatch call
  -h, --help             Show help

Examples:
  ./test-github-app-dispatch.sh --client-id Iv23xxxxx --private-key ~/dystopianbot.pem
  ./test-github-app-dispatch.sh --client-id Iv23xxxxx --private-key ~/dystopianbot.pem --no-dispatch
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

CLIENT_ID=""
PRIVATE_KEY=""
OWNER="DystopianOS"
REPO="Dystopian-PKGBUILDS"
WORKFLOW="build_repo.yml"
REF="main"
INPUT_PACKAGE="dystopian-keyring"
INPUT_CHANNEL="x86_64"
DO_DISPATCH="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-id) CLIENT_ID="${2:-}"; shift 2 ;;
    --app-id) CLIENT_ID="${2:-}"; shift 2 ;;
    --private-key) PRIVATE_KEY="${2:-}"; shift 2 ;;
    --owner) OWNER="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --workflow) WORKFLOW="${2:-}"; shift 2 ;;
    --ref) REF="${2:-}"; shift 2 ;;
    --package) INPUT_PACKAGE="${2:-}"; shift 2 ;;
    --channel) INPUT_CHANNEL="${2:-}"; shift 2 ;;
    --no-dispatch) DO_DISPATCH="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$CLIENT_ID" || -z "$PRIVATE_KEY" ]]; then
  echo "Error: --client-id and --private-key are required." >&2
  usage
  exit 2
fi
if [[ ! -f "$PRIVATE_KEY" ]]; then
  echo "Error: private key file not found: $PRIVATE_KEY" >&2
  exit 2
fi

require_cmd curl
require_cmd jq
require_cmd openssl

now=$(date +%s)
iat=$((now - 60))
exp=$((now + 540))

header='{"alg":"RS256","typ":"JWT"}'
payload="{\"iat\":${iat},\"exp\":${exp},\"iss\":\"${CLIENT_ID}\"}"

h=$(printf '%s' "$header" | b64url)
p=$(printf '%s' "$payload" | b64url)
s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$PRIVATE_KEY" | b64url)
jwt="${h}.${p}.${s}"

echo "Checking installation for org '${OWNER}'..."
inst_resp=$(curl -sS -w '\n%{http_code}' \
  -H "Authorization: Bearer ${jwt}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/${OWNER}/installation")
inst_body=$(printf '%s' "$inst_resp" | sed '$d')
inst_code=$(printf '%s' "$inst_resp" | tail -n1)

if [[ "$inst_code" != "200" ]]; then
  echo "Failed to resolve installation (HTTP ${inst_code})." >&2
  printf '%s\n' "$inst_body" | jq . >&2 || printf '%s\n' "$inst_body" >&2
  exit 1
fi

inst_id=$(printf '%s' "$inst_body" | jq -r '.id')
echo "Installation ID: ${inst_id}"

echo "Minting installation token..."
tok_resp=$(curl -sS -w '\n%{http_code}' \
  -X POST \
  -H "Authorization: Bearer ${jwt}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${inst_id}/access_tokens")
tok_body=$(printf '%s' "$tok_resp" | sed '$d')
tok_code=$(printf '%s' "$tok_resp" | tail -n1)

if [[ "$tok_code" != "201" ]]; then
  echo "Failed to mint installation token (HTTP ${tok_code})." >&2
  printf '%s\n' "$tok_body" | jq . >&2 || printf '%s\n' "$tok_body" >&2
  exit 1
fi

token=$(printf '%s' "$tok_body" | jq -r '.token')
token_len=$(printf '%s' "$token" | wc -c | tr -d ' ')
echo "Installation token created (length ${token_len})."

echo "Checking actions access on ${OWNER}/${REPO}..."
repo_resp=$(curl -sS -w '\n%{http_code}' \
  -H "Authorization: Bearer ${token}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${OWNER}/${REPO}/actions/workflows/${WORKFLOW}")
repo_body=$(printf '%s' "$repo_resp" | sed '$d')
repo_code=$(printf '%s' "$repo_resp" | tail -n1)
if [[ "$repo_code" != "200" ]]; then
  echo "Repo workflow read failed (HTTP ${repo_code})." >&2
  printf '%s\n' "$repo_body" | jq . >&2 || printf '%s\n' "$repo_body" >&2
  exit 1
fi
echo "Workflow access OK."

if [[ "$DO_DISPATCH" != "true" ]]; then
  echo "Skipping dispatch by request (--no-dispatch)."
  exit 0
fi

echo "Dispatching ${WORKFLOW} on ${OWNER}/${REPO}..."
dispatch_payload=$(jq -cn \
  --arg ref "$REF" \
  --arg package "$INPUT_PACKAGE" \
  --arg channel "$INPUT_CHANNEL" \
  '{ref:$ref,inputs:{package:$package,channel:$channel}}')

dispatch_resp=$(curl -sS -w '\n%{http_code}' \
  -X POST \
  -H "Authorization: Bearer ${token}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${OWNER}/${REPO}/actions/workflows/${WORKFLOW}/dispatches" \
  -d "$dispatch_payload")
dispatch_body=$(printf '%s' "$dispatch_resp" | sed '$d')
dispatch_code=$(printf '%s' "$dispatch_resp" | tail -n1)

if [[ "$dispatch_code" != "204" ]]; then
  echo "Dispatch failed (HTTP ${dispatch_code})." >&2
  if [[ -n "$dispatch_body" ]]; then
    printf '%s\n' "$dispatch_body" | jq . >&2 || printf '%s\n' "$dispatch_body" >&2
  fi
  exit 1
fi

echo "Dispatch succeeded."
