#!/usr/bin/env bash
# Tests the smoke_test step of .github/workflows/docker-build.yaml, which
# starts a Postgres container and the built image, then polls the health
# endpoints. Extracts the step's `run:` body and runs it locally against
# stubbed docker and curl commands, checking all validation, port detection,
# env handling, polling logic, and cleanup cases.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/docker-build.yaml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Print the de-indented `run: |` body of the workflow step whose `id:` is $2
# in workflow file $1 (steps at 6 spaces, keys at 8, run body at 10).
extract_step() {
  awk -v want="$2" '
    /^      - / { in_step = 0 }
    $0 ~ "^        id: " want "$" { in_step = 1; next }
    in_step && /^        run: \|$/ { in_run = 1; next }
    in_run {
      if ($0 ~ /^      - / || ($0 !~ /^[[:space:]]*$/ && $0 !~ /^          /)) { exit }
      print
    }
  ' "$1" | sed -e 's/^          //'
}

extract_step "$WORKFLOW" smoke_test > "$TMP/smoke.sh"
if ! grep -q 'IMAGE' "$TMP/smoke.sh"; then
  echo "FAIL extract smoke_test step (empty or polluted extraction)"; exit 1
fi

pass=0; fail=0
ERR="$TMP/err"

# Create stub directory
mkdir -p "$TMP/bin"

# Stub: docker logs all invocations; inspect -f '{{json .Config.ExposedPorts}}'
# returns $FAKE_EXPOSED; exec ... pg_isready exits $FAKE_PG_RC; run ... smoke-app
# exits $FAKE_RUN_RC (prints $FAKE_RUN_ERR to stderr when non-zero); inspect -f
# on smoke-app pops a line from $TMP/states (repeats last); logs prints marker; rm succeeds.
cat > "$TMP/bin/docker" << 'EOSTUB'
#!/usr/bin/env bash
echo "$*" >> "$TMP/docker.log"
if [[ "$1" == "image" && "$2" == "inspect" ]]; then
  echo "${FAKE_EXPOSED:-null}"
elif [[ "$1" == "exec" && "$2" == "smoke-postgres" && "$3" == "pg_isready" ]]; then
  exit "${FAKE_PG_RC:-0}"
elif [[ "$1" == "run" && "$*" == *"smoke-app"* ]]; then
  rc="${FAKE_RUN_RC:-0}"
  if [[ "$rc" != 0 ]]; then
    echo "${FAKE_RUN_ERR:-}" >&2
  fi
  exit "$rc"
elif [[ "$1" == "run" ]]; then
  # Postgres or other container - just succeed
  exit 0
elif [[ "$1" == "inspect" && "$*" == *"smoke-app"* ]]; then
  if [[ -f "$TMP/states" && -s "$TMP/states" ]]; then
    state="$(head -n1 "$TMP/states")"
    tail -n +2 "$TMP/states" > "$TMP/states.tmp" || true
    if [[ -s "$TMP/states.tmp" ]]; then
      mv "$TMP/states.tmp" "$TMP/states"
    else
      # Last state repeats
      echo "$state" > "$TMP/states"
    fi
    echo "$state"
  else
    echo "running 0"
  fi
elif [[ "$1" == "logs" ]]; then
  echo "APP-LOG-MARKER"
elif [[ "$1" == "rm" ]]; then
  # cleanup succeeds
  exit 0
fi
EOSTUB
chmod +x "$TMP/bin/docker"

# Stub: curl finds the URL argument, looks up its path in $TMP/codes (lines
# "PATH CODE"), prints the code (default 000); appends URL to $TMP/curl.log.
# Exits 7 when printing 000 (to test curl failure handling).
cat > "$TMP/bin/curl" << 'EOSTUB'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  if [[ "$arg" =~ ^http ]]; then
    url="$arg"
    break
  fi
done
if [[ -n "$url" ]]; then
  echo "$url" >> "$TMP/curl.log"
  path="${url#http://*/}"
  path="/${path}"
  code="000"
  if [[ -f "$TMP/codes" ]]; then
    found="$(awk -v p="$path" '$1 == p {print $2}' "$TMP/codes")"
    if [[ -n "$found" ]]; then
      code="$found"
    fi
  fi
  echo "$code"
  if [[ "$code" == "000" ]]; then
    exit 7
  fi
fi
EOSTUB
chmod +x "$TMP/bin/curl"

# Stub: sleep is a no-op (so polling rounds are bounded by count, not time)
cat > "$TMP/bin/sleep" << 'EOSTUB'
#!/usr/bin/env bash
# no-op
EOSTUB
chmod +x "$TMP/bin/sleep"

# run_smoke VAR=value ... -> runs the smoke script with defaults
run_smoke() {
  : > "$TMP/docker.log"
  : > "$TMP/curl.log"
  mkdir -p "$TMP/rt"
  (cd "$TMP" && env -i PATH="$TMP/bin:$PATH" RUNNER_TEMP="$TMP/rt" IMAGE=img SMOKE_TIMEOUT_SECONDS=6 SMOKE_POLL_SECONDS=2 PG_IMAGE=postgres:17.6 SMOKE_PATH="${SMOKE_PATH:-}" SMOKE_ENV="${SMOKE_ENV:-}" TMP="$TMP" FAKE_EXPOSED="${FAKE_EXPOSED:-}" FAKE_PG_RC="${FAKE_PG_RC:-}" FAKE_RUN_RC="${FAKE_RUN_RC:-}" FAKE_RUN_ERR="${FAKE_RUN_ERR:-}" "$@" bash --noprofile --norc -e -o pipefail "$TMP/smoke.sh") > "$ERR" 2>&1
  rc=$?
}

check() {
  local name="$1"; shift
  if "$@"; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    sed 's/^/    | /' "$ERR"
    fail=$((fail + 1))
  fi
}

docker_log_has() { grep -qF -- "$1" "$TMP/docker.log"; }
curl_log_has() { grep -qF -- "$1" "$TMP/curl.log"; }
output_has() { grep -qF -- "$1" "$ERR"; }
output_lacks() { ! grep -qF -- "$1" "$ERR"; }

# port from ExposedPorts
t() {
  FAKE_EXPOSED='{"80/tcp":{}}' run_smoke
  [[ "$rc" = 0 ]] && docker_log_has "-p 127.0.0.1:80:80" && curl_log_has "http://127.0.0.1:80/api/health/ready" && output_has "port 80"
}
setup_codes() {
  cat > "$TMP/codes" << EOF
/api/health/ready 200
EOF
}
setup_states() { echo "running 0" > "$TMP/states"; }
setup_codes; setup_states
check "port from ExposedPorts" t

# lowest of several ports
t() {
  FAKE_EXPOSED='{"443/tcp":{},"80/tcp":{}}' run_smoke
  [[ "$rc" = 0 ]] && docker_log_has "-p 127.0.0.1:80:80"
}
setup_codes; setup_states
check "lowest of several ports" t

# udp-only falls back to 8080
t() {
  FAKE_EXPOSED='{"53/udp":{}}' run_smoke
  [[ "$rc" = 0 ]] && docker_log_has "-p 127.0.0.1:8080:8080"
}
setup_codes; setup_states
check "udp-only falls back to 8080" t

# no ExposedPorts falls back to 8080
t() {
  FAKE_EXPOSED='null' run_smoke
  [[ "$rc" = 0 ]] && docker_log_has "-p 127.0.0.1:8080:8080"
}
setup_codes; setup_states
check "no ExposedPorts falls back to 8080" t

# network namespace
t() {
  run_smoke
  docker_log_has "--network container:smoke-postgres" && ! docker_log_has "--network host"
}
setup_codes; setup_states
check "network namespace" t

# default env then caller env
t() {
  SMOKE_ENV=$'Database__Provider=Sqlite\nFoo__Bar=1' run_smoke
  [[ "$rc" = 0 ]] &&
  env_file="$(cat "$TMP/rt/smoke-test.env")" &&
  [[ "$(echo "$env_file" | head -n1)" == "Database__Provider=PostgreSQL" ]] &&
  [[ "$(echo "$env_file" | sed -n '2p')" =~ ^ConnectionStrings__PostgreSQL= ]] &&
  [[ "$(echo "$env_file" | sed -n '3p')" =~ ^Database__ConnectionString= ]] &&
  [[ "$(echo "$env_file" | sed -n '4p')" == "Oidc__RequireHttpsMetadata=false" ]] &&
  [[ "$(echo "$env_file" | sed -n '5p')" == "GameEngine__ClientId=smoketest" ]] &&
  [[ "$(echo "$env_file" | sed -n '6p')" == "GameEngine__ClientSecret=smoketest" ]] &&
  [[ "$(echo "$env_file" | sed -n '7p')" == "Database__Provider=Sqlite" ]] &&
  [[ "$(echo "$env_file" | sed -n '8p')" == "Foo__Bar=1" ]]
}
setup_codes; setup_states
check "default env then caller env" t

# CRLF and blank lines in env
t() {
  SMOKE_ENV=$'A=1\r\n\r\nB=2\r\n' run_smoke
  [[ "$rc" = 0 ]] &&
  env_file="$(cat "$TMP/rt/smoke-test.env")" &&
  echo "$env_file" | grep -qF "A=1" &&
  echo "$env_file" | grep -qF "B=2" &&
  ! echo "$env_file" | grep -q $'\r'
}
setup_codes; setup_states
check "CRLF and blank lines in env" t

# invalid env line not echoed
t() {
  SMOKE_ENV=$'A=1\nexport SECRETVALUE=x' run_smoke
  [[ "$rc" != 0 ]] && output_has "line 2" && output_lacks "SECRETVALUE" && ! docker_log_has "run "
}
check "invalid env line not echoed" t

# explicit path
t() {
  SMOKE_PATH=/api/x run_smoke
  [[ "$rc" = 0 ]] && curl_log_has "http://127.0.0.1:8080/api/x" &&
  ! curl_log_has "/api/health/ready"
}
cat > "$TMP/codes" << EOF
/api/x 200
EOF
setup_states
check "explicit path" t

# path without leading slash rejected
t() {
  SMOKE_PATH=api/x run_smoke
  [[ "$rc" != 0 ]] && ! docker_log_has "run "
}
check "path without leading slash rejected" t

# default list fallback
t() {
  run_smoke
  [[ "$rc" = 0 ]] &&
  curl_log_has "/api/health/ready" &&
  curl_log_has "/api/health/version" &&
  curl_log_has "/api/status" &&
  # Check order: ready and version before status
  ready_line="$(grep -n "/api/health/ready" "$TMP/curl.log" | head -1 | cut -d: -f1)" &&
  version_line="$(grep -n "/api/health/version" "$TMP/curl.log" | head -1 | cut -d: -f1)" &&
  status_line="$(grep -n "/api/status" "$TMP/curl.log" | head -1 | cut -d: -f1)" &&
  [[ "$ready_line" -lt "$status_line" ]] && [[ "$version_line" -lt "$status_line" ]] &&
  output_has "Smoke test passed: /api/status returned 200 on port"
}
cat > "$TMP/codes" << EOF
/api/health/ready 000
/api/health/version 000
/api/status 200
EOF
setup_states
check "default list fallback" t

# 503 keeps polling
t() {
  run_smoke
  curl_rounds="$(wc -l < "$TMP/curl.log")"
  # At 6s timeout, 2s poll: 3 rounds * 4 paths = 12 attempts minimum
  [[ "$rc" != 0 ]] && output_has "503" && output_has "Timeout" && [[ "$curl_rounds" -ge 12 ]]
}
cat > "$TMP/codes" << EOF
/api/health/ready 503
EOF
setup_states
check "503 keeps polling" t

# exited container fails fast
t() {
  run_smoke
  [[ "$rc" != 0 ]] && output_has "135" && output_has "APP-LOG-MARKER" &&
  curl_count="$(wc -l < "$TMP/curl.log" || echo 0)" &&
  [[ "$curl_count" -le 4 ]]
}
echo "exited 135" > "$TMP/states"
: > "$TMP/codes"
check "exited container fails fast" t

# docker run fails
t() {
  FAKE_RUN_RC=125 FAKE_RUN_ERR='exec format error' run_smoke
  [[ "$rc" != 0 ]] && output_has "exec format error" &&
  tail -1 "$TMP/docker.log" | grep -qF "rm -f" &&
  tail -1 "$TMP/docker.log" | grep -qF "smoke-app" &&
  tail -1 "$TMP/docker.log" | grep -qF "smoke-postgres"
}
check "docker run fails" t

# postgres never ready
t() {
  FAKE_PG_RC=1 run_smoke
  [[ "$rc" != 0 ]] && output_has "Postgres" && ! docker_log_has "--name smoke-app" && docker_log_has "rm -f"
}
check "postgres never ready" t

# cleanup on success
t() {
  run_smoke
  [[ "$rc" = 0 ]] && docker_log_has "rm -f" && docker_log_has "smoke-app" && docker_log_has "smoke-postgres"
}
setup_codes; setup_states
check "cleanup on success" t

# logs on timeout
t() {
  run_smoke
  [[ "$rc" != 0 ]] && output_has "APP-LOG-MARKER" && output_has "::group::"
}
cat > "$TMP/codes" << EOF
/api/health/ready 503
EOF
setup_states
check "logs on timeout" t

# GitHub annotation
t() {
  run_smoke
  [[ "$rc" != 0 ]] && output_has "::error title=Smoke test failed::"
}
echo "exited 135" > "$TMP/states"
: > "$TMP/codes"
check "GitHub annotation" t

# ============ Structural checks for Task 2: wiring into build flow ============

# Parse step blocks from the workflow (steps at 6 spaces, keys at 8, content at 10+).
# For each step, extract: name, id (if any), if (if any), and uses/run marker.

# Extract step name by pattern (returns first match or empty)
step_name_line() {
  awk -v pat="$1" '
    /^      - name: / && $0 ~ pat { print; exit }
  ' "$WORKFLOW"
}

# Extract step field value (name $1, field $2 like "id:" or "if:")
step_field() {
  awk -v step="$1" -v field="$2" '
    /^      - / { in_step = 0 }
    $0 ~ "^      - name: " step "$" { in_step = 1; next }
    in_step && $0 ~ "^        " field " " {
      line = $0
      sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", line)
      print line
      exit
    }
  ' "$WORKFLOW"
}

# Check that a uses: step has a specific attribute in its with: block
step_with_has() {
  local step_name="$1" attr="$2" expected="$3"
  awk -v step="$step_name" -v attr="$attr" -v expected="$expected" '
    /^      - / { in_step = 0; in_with = 0 }
    $0 ~ "^      - name: " step "$" { in_step = 1; next }
    in_step && /^        with:$/ { in_with = 1; next }
    in_with && $0 ~ "^          " attr ": " {
      sub(/^[[:space:]]*[^[:space:]]+:[[:space:]]*/, "")
      if ($0 == expected) exit 0
      else exit 1
    }
    in_with && /^        [^[:space:]]/ { exit 1 }
  ' "$WORKFLOW"
}

# build_smoke exists with correct attributes
t() {
  [[ -n "$(step_name_line 'Build default stage for smoke test')" ]] &&
  [[ "$(step_field 'Build default stage for smoke test' 'id:')" == "build_smoke" ]] &&
  [[ "$(step_field 'Build default stage for smoke test' 'if:')" == "inputs.smokeTest" ]] &&
  step_with_has 'Build default stage for smoke test' 'load' 'true' &&
  step_with_has 'Build default stage for smoke test' 'push' 'false' &&
  step_with_has 'Build default stage for smoke test' 'tags' 'smoke-test:local' &&
  # No target: means additionalTarget is not used for smoke test
  ! awk '/^      - name: Build default stage for smoke test$/,/^      - / {if(/^          target:/) exit 0} END{exit 1}' "$WORKFLOW" &&
  # cache-from scope matches default stage pattern
  step_with_has 'Build default stage for smoke test' 'cache-from' "type=gha,scope=\${{ needs.prepare.outputs.image_slug }}-\${{ matrix.safe }}-default"
}
check "build_smoke exists with correct attributes" t

# smoke_test has if: inputs.smokeTest
t() {
  [[ "$(step_field 'Smoke test default stage' 'if:')" == "inputs.smokeTest" ]]
}
check "smoke_test has if: inputs.smokeTest" t

# Step order: build_smoke < smoke_test < build_default_push
t() {
  build_smoke_line="$(grep -n '^      - name: Build default stage for smoke test$' "$WORKFLOW" | cut -d: -f1)"
  smoke_test_line="$(grep -n '^      - name: Smoke test default stage$' "$WORKFLOW" | cut -d: -f1)"
  build_push_line="$(grep -n '^      - name: Build (push by digest) default stage$' "$WORKFLOW" | cut -d: -f1)"
  [[ -n "$build_smoke_line" ]] && [[ -n "$smoke_test_line" ]] && [[ -n "$build_push_line" ]] &&
  [[ "$build_smoke_line" -lt "$smoke_test_line" ]] &&
  [[ "$smoke_test_line" -lt "$build_push_line" ]]
}
check "step order: build_smoke < smoke_test < build_default_push" t

# Build (no push) default stage has updated if:
t() {
  if_cond="$(step_field 'Build \(no push\) default stage' 'if:')"
  [[ "$if_cond" == "needs.prepare.outputs.push != 'true' && !inputs.smokeTest" ]]
}
check "Build (no push) default stage has updated if condition" t

# No other step if: changed (baseline from origin/main)
# Expected if: lines (step name | if: condition) from origin/main, excluding the ones we change
expected_ifs=(
  "Pre-build commands|inputs.preBuildCommands != ''"
  "Inject version into package.json files \\(npm\\)|inputs.versionMode == 'npm' && steps.version.outputs.version != '' && inputs.versionFiles != ''"
  "Prepare build args for .NET version \\(csproj\\)|inputs.versionMode == 'csproj' && steps.version.outputs.version != ''"
  "Login to Docker Hub|needs.prepare.outputs.push == 'true'"
  "Build \\(push by digest\\) default stage|needs.prepare.outputs.push == 'true'"
  "Export default digest|needs.prepare.outputs.push == 'true'"
  "Upload default digest|needs.prepare.outputs.push == 'true'"
  "Build \\(push by digest\\) additional target|needs.prepare.outputs.push == 'true' && needs.prepare.outputs.has_additional_target == 'true'"
  "Build \\(no push\\) additional target|needs.prepare.outputs.push != 'true' && needs.prepare.outputs.has_additional_target == 'true'"
  "Export additional digest|needs.prepare.outputs.push == 'true' && needs.prepare.outputs.has_additional_target == 'true'"
  "Upload additional digest|needs.prepare.outputs.push == 'true' && needs.prepare.outputs.has_additional_target == 'true'"
)
t() {
  for entry in "${expected_ifs[@]}"; do
    step_name="${entry%%|*}"
    expected_if="${entry#*|}"
    actual_if="$(step_field "$step_name" 'if:')"
    if [[ "$actual_if" != "$expected_if" ]]; then
      echo "Step '$step_name' if: changed: expected '$expected_if', got '$actual_if'" >&2
      return 1
    fi
  done
  return 0
}
check "no other step if: changed from origin/main" t

echo "docker-build-smoke: $pass passed, $fail failed"
[ "$fail" = 0 ]
