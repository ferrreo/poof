#!/usr/bin/env bash
set -Eeuo pipefail

readonly CADDY_IMAGE="docker.io/library/caddy:2.11.4-alpine@"\
"sha256:98eb57d882ccd5213d1688764db10c1ca2c58a1ca3a6717a3411ad798f7a423a"
readonly NGINX_IMAGE="docker.io/library/nginx:1.30.4-alpine@"\
"sha256:8a4f4b94275ff59d809477799cbbaf1a7ab65ed1871403d05e31fd66bdb8db82"

if [[ $# -ne 4 || ( $1 != --required && $1 != --optional ) ]]; then
    echo "usage: $0 (--required|--optional) DEBUG SAFE FAST" >&2
    exit 2
fi

readonly POLICY=$1
shift
readonly ORIGINS=("$1" "$2" "$3")
readonly MODES=("Debug" "ReleaseSafe" "ReleaseFast")
readonly ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly PROXY_DIR="$ROOT/tests/proxy"
readonly TEMP_DIR=$(mktemp -d)
readonly COMPRESSED_REQUEST="$TEMP_DIR/compressed-request.gz"
readonly UPLOAD_PAYLOAD="$TEMP_DIR/payload.bin"

ORIGIN_PID=""
ORIGIN_OUT=""
ORIGIN_ERR=""
ORIGIN_PORT=""
CURRENT_CONTAINER=""
CASE_COUNTER=0
HTTP_CASES=0
TOPOLOGY_CASES=0
CASE_BASE_URL=""
CASE_ABSOLUTE_TARGET=false
CASE_CURL_ARGS=()
RESPONSE_HEADERS=""
RESPONSE_BODY=""

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if [[ $status -ne 0 ]]; then
        [[ -n $ORIGIN_OUT && -f $ORIGIN_OUT ]] && cat "$ORIGIN_OUT" >&2
        [[ -n $ORIGIN_ERR && -f $ORIGIN_ERR ]] && cat "$ORIGIN_ERR" >&2
        if [[ -n $CURRENT_CONTAINER ]]; then
            docker logs "$CURRENT_CONTAINER" >&2
        fi
    fi
    if [[ -n $ORIGIN_PID ]]; then
        kill "$ORIGIN_PID" 2>/dev/null
        wait "$ORIGIN_PID" 2>/dev/null
    fi
    if [[ -n $CURRENT_CONTAINER ]]; then
        docker rm -f "$CURRENT_CONTAINER" >/dev/null 2>&1
    fi
    rm -rf -- "$TEMP_DIR"
    exit "$status"
}
trap cleanup EXIT INT TERM

die() {
    echo "proxy interop failed: $*" >&2
    exit 1
}

unavailable() {
    if [[ $POLICY == --required ]]; then
        die "$1"
    fi
    echo "SKIP proxy interop: $1" >&2
    exit 0
}

start_origin() {
    local executable=$1
    local mode=$2
    local case_name=$3
    ORIGIN_OUT="$TEMP_DIR/${case_name}.out"
    ORIGIN_ERR="$TEMP_DIR/${case_name}.err"
    "$executable" "$mode" 13 >"$ORIGIN_OUT" 2>"$ORIGIN_ERR" &
    ORIGIN_PID=$!
    ORIGIN_PORT=""

    local attempt
    for ((attempt = 0; attempt < 200; attempt += 1)); do
        ORIGIN_PORT=$(sed -n 's/^READY \([0-9][0-9]*\)$/\1/p' \
            "$ORIGIN_OUT" | head -n 1)
        [[ -n $ORIGIN_PORT ]] && break
        if ! kill -0 "$ORIGIN_PID" 2>/dev/null; then
            wait "$ORIGIN_PID" || true
            die "$case_name origin exited before readiness"
        fi
        sleep 0.05
    done
    [[ $ORIGIN_PORT =~ ^[0-9]+$ ]] || die "$case_name origin readiness timed out"
    ((ORIGIN_PORT > 0 && ORIGIN_PORT <= 65535)) || die "$case_name returned invalid port"
}

finish_origin() {
    local case_name=$1
    if ! wait "$ORIGIN_PID"; then
        ORIGIN_PID=""
        die "$case_name origin failed"
    fi
    ORIGIN_PID=""
}

hostile_request() {
    curl --http1.1 --noproxy '*' --silent --show-error \
        --path-as-is \
        --connect-timeout 3 --max-time 10 \
        -H 'Host: app.test' \
        -H 'Forwarded: not valid ]]]' \
        -H 'X-Forwarded-For: totally invalid' \
        -H 'X-Forwarded-Host: attacker.test' \
        -H 'X-Forwarded-Proto: http' \
        "$@"
}

header_count() {
    local file=$1 name=$2
    awk -v name="$name" '
        {
            sub(/\r$/, "")
            if (index(tolower($0), tolower(name) ":") == 1) count += 1
        }
        END { print count + 0 }
    ' "$file"
}

header_value() {
    local file=$1 name=$2
    awk -v name="$name" '
        {
            sub(/\r$/, "")
            if (index(tolower($0), tolower(name) ":") == 1) {
                value = substr($0, length(name) + 2)
                sub(/^[ \t]+/, "", value)
                print value
            }
        }
    ' "$file" | tail -n 1
}

expect_header() {
    local case_name=$1 name=$2 expected=$3
    local count actual
    count=$(header_count "$RESPONSE_HEADERS" "$name")
    [[ $count == 1 ]] || \
        die "$case_name expected one $name response field, got $count"
    actual=$(header_value "$RESPONSE_HEADERS" "$name")
    [[ $actual == "$expected" ]] || \
        die "$case_name expected $name: $expected, got: $actual"
}

expect_header_value() {
    local case_name=$1 name=$2 expected=$3 count
    count=$(awk -v name="$name" -v expected="$expected" '
        {
            sub(/\r$/, "")
            if (index(tolower($0), tolower(name) ":") != 1) next
            value = substr($0, length(name) + 2)
            sub(/^[ \t]+/, "", value)
            if (value == expected) count += 1
        }
        END { print count + 0 }
    ' "$RESPONSE_HEADERS")
    [[ $count == 1 ]] || \
        die "$case_name expected one $name value '$expected', got $count"
}

expect_vary_pair() {
    local case_name=$1 first=$2 second=$3 count
    count=$(header_count "$RESPONSE_HEADERS" Vary)
    [[ $count == 2 ]] || die "$case_name expected two Vary fields, got $count"
    expect_header_value "$case_name" Vary "$first"
    expect_header_value "$case_name" Vary "$second"
}

expect_no_header() {
    local case_name=$1 name=$2
    local count
    count=$(header_count "$RESPONSE_HEADERS" "$name")
    [[ $count == 0 ]] || die "$case_name unexpectedly returned $name"
}

expect_proxy_body() {
    expect_body "$1" proxy-ok
}

expect_body() {
    local case_name=$1 expected=$2 body
    body=$(<"$RESPONSE_BODY")
    [[ $body == "$expected" ]] || \
        die "$case_name returned unexpected body: $body"
}

expect_uniform_body() {
    local case_name=$1 expected_byte=$2 expected_length=$3 body remainder
    body=$(<"$RESPONSE_BODY")
    remainder=${body//"$expected_byte"/}
    [[ ${#body} -eq expected_length && -z $remainder ]] || \
        die "$case_name expected $expected_length '$expected_byte' bytes"
}

expect_empty_body() {
    local case_name=$1
    [[ ! -s $RESPONSE_BODY ]] || die "$case_name returned a nonempty body"
}

request_case() {
    local case_name=$1 expected_status=$2 path=$3
    shift 3
    RESPONSE_HEADERS="$TEMP_DIR/${case_name}.headers"
    RESPONSE_BODY="$TEMP_DIR/${case_name}.body"

    local target_args=()
    if [[ $CASE_ABSOLUTE_TARGET == true ]]; then
        target_args=(--request-target "http://app.test${path}")
    fi

    local status
    if ! status=$(hostile_request \
        "${CASE_CURL_ARGS[@]}" \
        "${target_args[@]}" \
        --dump-header "$RESPONSE_HEADERS" \
        --output "$RESPONSE_BODY" \
        --write-out '%{http_code}' \
        "$@" \
        "${CASE_BASE_URL}${path}"); then
        die "$case_name request failed"
    fi
    [[ $status == "$expected_status" ]] || \
        die "$case_name expected HTTP $expected_status, got $status"
    HTTP_CASES=$((HTTP_CASES + 1))
}

run_cors_cases() {
    local case_name=$1

    request_case "$case_name-identity" 200 /identity
    expect_proxy_body "$case_name-identity"
    expect_no_header "$case_name-identity" Access-Control-Allow-Origin
    expect_header "$case_name-identity" Vary Accept-Encoding

    request_case "$case_name-wildcard" 200 /cors/wildcard \
        -H 'Origin: https://other.example'
    expect_proxy_body "$case_name-wildcard"
    expect_header "$case_name-wildcard" Access-Control-Allow-Origin '*'
    expect_vary_pair "$case_name-wildcard" Origin Accept-Encoding
    expect_no_header "$case_name-wildcard" Access-Control-Allow-Credentials

    request_case "$case_name-credentialed" 200 /cors/credentialed \
        -H 'Origin: https://app.example'
    expect_proxy_body "$case_name-credentialed"
    expect_header "$case_name-credentialed" Access-Control-Allow-Origin \
        'https://app.example'
    expect_header "$case_name-credentialed" Access-Control-Allow-Credentials true
    expect_vary_pair "$case_name-credentialed" Origin Accept-Encoding

    request_case "$case_name-null-allow" 200 /cors/null-allow -H 'Origin: null'
    expect_proxy_body "$case_name-null-allow"
    expect_header "$case_name-null-allow" Access-Control-Allow-Origin '*'
    expect_vary_pair "$case_name-null-allow" Origin Accept-Encoding
    expect_no_header "$case_name-null-allow" Access-Control-Allow-Credentials

    request_case "$case_name-preflight-allow" 204 /cors/preflight \
        --request OPTIONS \
        -H 'Origin: https://app.example' \
        -H 'Access-Control-Request-Method: POST' \
        -H 'Access-Control-Request-Headers: X-Trace'
    expect_empty_body "$case_name-preflight-allow"
    expect_header "$case_name-preflight-allow" Access-Control-Allow-Origin \
        'https://app.example'
    expect_header "$case_name-preflight-allow" Access-Control-Allow-Methods POST
    expect_header "$case_name-preflight-allow" Access-Control-Allow-Headers X-Trace
    expect_header "$case_name-preflight-allow" Access-Control-Max-Age 600
    expect_header "$case_name-preflight-allow" Vary \
        'Origin, Access-Control-Request-Method, Access-Control-Request-Headers'
    expect_no_header "$case_name-preflight-allow" Access-Control-Allow-Credentials

    request_case "$case_name-preflight-deny" 403 /cors/preflight \
        --request OPTIONS \
        -H 'Origin: https://app.example' \
        -H 'Access-Control-Request-Method: POST' \
        -H 'Access-Control-Request-Headers: X-Denied'
    expect_empty_body "$case_name-preflight-deny"
    expect_no_header "$case_name-preflight-deny" Access-Control-Allow-Origin
    expect_no_header "$case_name-preflight-deny" Access-Control-Allow-Methods
    expect_no_header "$case_name-preflight-deny" Access-Control-Allow-Headers
    expect_header "$case_name-preflight-deny" Vary \
        'Origin, Access-Control-Request-Method, Access-Control-Request-Headers'
}

run_transport_cases() {
    local case_name=$1

    request_case "$case_name-compression" 200 /compression \
        --request POST \
        --compressed \
        -H 'Accept-Encoding: gzip' \
        -H 'Content-Encoding: gzip' \
        -H 'Content-Type: application/octet-stream' \
        --data-binary "@$COMPRESSED_REQUEST"
    expect_header "$case_name-compression" Content-Encoding gzip
    expect_header "$case_name-compression" Vary Accept-Encoding
    expect_uniform_body "$case_name-compression" z 4096

    request_case "$case_name-stream" 200 /stream
    expect_uniform_body "$case_name-stream" s 32768
    expect_header "$case_name-stream" Vary Accept-Encoding
    expect_no_header "$case_name-stream" Content-Encoding

    request_case "$case_name-path-encoded-slash" 200 /normal%2Fslash
    expect_body "$case_name-path-encoded-slash" path-ok

    request_case "$case_name-path-encoded-backslash" 200 /normal%5Cbackslash
    expect_body "$case_name-path-encoded-backslash" path-ok

    request_case "$case_name-path-double-encoded-slash" 200 /normal%252Fdouble
    expect_body "$case_name-path-double-encoded-slash" path-ok

    request_case "$case_name-path-encoded-unreserved" 200 /normal/%75nreserved
    expect_body "$case_name-path-encoded-unreserved" path-ok

    request_case "$case_name-path-encoded-dot" 200 /normal/%2e/dot
    expect_body "$case_name-path-encoded-dot" path-ok

    request_case "$case_name-upload" 200 /upload \
        --request POST \
        -H 'Transfer-Encoding: chunked' \
        --form 'count=42' \
        --form "upload=@$UPLOAD_PAYLOAD;filename=payload.bin;type=application/octet-stream"
    expect_body "$case_name-upload" upload-ok
    expect_header "$case_name-upload" Vary Accept-Encoding
}

run_matrix() {
    local case_name=$1
    TOPOLOGY_CASES=$((TOPOLOGY_CASES + 1))

    run_cors_cases "$case_name"
    run_transport_cases "$case_name"

    request_case "$case_name-null-deny" 200 /finish -H 'Origin: null'
    expect_proxy_body "$case_name-null-deny"
    expect_no_header "$case_name-null-deny" Access-Control-Allow-Origin
    expect_vary_pair "$case_name-null-deny" Origin Accept-Encoding

    echo "PASS $case_name (15 HTTP cases)"
}

prepare_fixtures() {
    printf '%s' 'compressed-request-payload' | gzip -n >"$COMPRESSED_REQUEST"
    awk 'BEGIN { for (i = 0; i < 65536; i += 1) printf "p" }' >"$UPLOAD_PAYLOAD"
    [[ -s $COMPRESSED_REQUEST && $(wc -c <"$UPLOAD_PAYLOAD") == 65536 ]] || \
        die "proxy request fixture generation failed"
}

run_direct() {
    local executable=$1
    local optimize=$2
    local case_name="${optimize}-direct"
    start_origin "$executable" direct "$case_name"
    CASE_BASE_URL="http://127.0.0.1:${ORIGIN_PORT}"
    CASE_ABSOLUTE_TARGET=true
    CASE_CURL_ARGS=()
    run_matrix "$case_name"
    finish_origin "$case_name"
}

stop_container() {
    docker rm -f "$CURRENT_CONTAINER" >/dev/null
    CURRENT_CONTAINER=""
}

container_port() {
    local attempt mapping
    for ((attempt = 0; attempt < 100; attempt += 1)); do
        mapping=$(docker port "$CURRENT_CONTAINER" 8443/tcp 2>/dev/null || true)
        if [[ $mapping =~ ^127\.0\.0\.1:([0-9]+)$ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
        sleep 0.05
    done
    return 1
}

wait_for_tls_port() {
    local port=$1
    local attempt
    for ((attempt = 0; attempt < 200; attempt += 1)); do
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            exec 3>&-
            return 0
        fi
        if [[ $(docker inspect -f '{{.State.Running}}' \
            "$CURRENT_CONTAINER" 2>/dev/null) != true ]]; then
            return 1
        fi
        sleep 0.05
    done
    return 1
}

start_caddy() {
    local backend_port=$1
    local config_file=$2
    CURRENT_CONTAINER="ploof-caddy-$$-$((CASE_COUNTER += 1))"
    docker run -d --name "$CURRENT_CONTAINER" --pull never \
        --platform linux/amd64 \
        --add-host host.docker.internal:host-gateway \
        -e "BACKEND_PORT=$backend_port" \
        -p 127.0.0.1::8443 \
        -v "$config_file:/etc/caddy/Caddyfile:ro" \
        -v "$PROXY_DIR/interop.crt:/etc/ploof/interop.crt:ro" \
        -v "$PROXY_DIR/interop.key:/etc/ploof/interop.key:ro" \
        "$CADDY_IMAGE" >/dev/null
}

start_nginx() {
    local backend_port=$1
    CURRENT_CONTAINER="ploof-nginx-$$-$((CASE_COUNTER += 1))"
    docker run -d --name "$CURRENT_CONTAINER" --pull never \
        --platform linux/amd64 \
        --add-host host.docker.internal:host-gateway \
        -e "BACKEND_PORT=$backend_port" \
        -p 127.0.0.1::8443 \
        -v "$PROXY_DIR/nginx.conf.template:/etc/nginx/templates/default.conf.template:ro" \
        -v "$PROXY_DIR/interop.crt:/etc/ploof/interop.crt:ro" \
        -v "$PROXY_DIR/interop.key:/etc/ploof/interop.key:ro" \
        "$NGINX_IMAGE" >/dev/null
}

run_caddy() {
    local executable=$1 optimize=$2 config_name=$3 origin_mode=$4 suffix=$5
    local case_name="${optimize}-${suffix}"
    start_origin "$executable" "$origin_mode" "$case_name"
    start_caddy "$ORIGIN_PORT" "$PROXY_DIR/$config_name"

    local edge_port
    edge_port=$(container_port) || die "$case_name has no published TLS port"
    wait_for_tls_port "$edge_port" || die "$case_name did not start"
    CASE_BASE_URL="https://interop.test:${edge_port}"
    CASE_ABSOLUTE_TARGET=false
    CASE_CURL_ARGS=(
        --cacert "$PROXY_DIR/interop.crt"
        --resolve "interop.test:${edge_port}:127.0.0.1"
    )
    run_matrix "$case_name"
    finish_origin "$case_name"
    stop_container
}

run_nginx() {
    local executable=$1 optimize=$2
    local case_name="${optimize}-nginx-x-forwarded"
    start_origin "$executable" x-forwarded "$case_name"
    start_nginx "$ORIGIN_PORT"

    local edge_port
    edge_port=$(container_port) || die "$case_name has no published TLS port"
    wait_for_tls_port "$edge_port" || die "$case_name did not start"
    CASE_BASE_URL="https://interop.test:${edge_port}"
    CASE_ABSOLUTE_TARGET=false
    CASE_CURL_ARGS=(
        --cacert "$PROXY_DIR/interop.crt"
        --resolve "interop.test:${edge_port}:127.0.0.1"
    )
    run_matrix "$case_name"
    finish_origin "$case_name"
    stop_container
}

validate_configs() {
    local caddy_file
    for caddy_file in Caddyfile.x_forwarded Caddyfile.proxy_v2; do
        checked_container "caddy-${caddy_file##*.}" \
            --pull never --platform linux/amd64 \
            --add-host host.docker.internal:host-gateway \
            -e BACKEND_PORT=1 \
            -v "$PROXY_DIR/$caddy_file:/etc/caddy/Caddyfile:ro" \
            -v "$PROXY_DIR/interop.crt:/etc/ploof/interop.crt:ro" \
            -v "$PROXY_DIR/interop.key:/etc/ploof/interop.key:ro" \
            "$CADDY_IMAGE" caddy validate \
            --config /etc/caddy/Caddyfile --adapter caddyfile
    done
    checked_container nginx --pull never --platform linux/amd64 \
        --add-host host.docker.internal:host-gateway \
        -e BACKEND_PORT=1 \
        -v "$PROXY_DIR/nginx.conf.template:/etc/nginx/templates/default.conf.template:ro" \
        -v "$PROXY_DIR/interop.crt:/etc/ploof/interop.crt:ro" \
        -v "$PROXY_DIR/interop.key:/etc/ploof/interop.key:ro" \
        "$NGINX_IMAGE" nginx -t
}

checked_container() {
    local label=$1
    shift
    CURRENT_CONTAINER="ploof-check-${label}-$$-$((CASE_COUNTER += 1))"
    docker run -d --name "$CURRENT_CONTAINER" "$@" >/dev/null || \
        die "$label validation container could not start"
    local status
    status=$(docker wait "$CURRENT_CONTAINER") || die "$label validation did not finish"
    if [[ $status != 0 ]]; then
        docker logs "$CURRENT_CONTAINER" >&2 || true
        die "$label validation exited $status"
    fi
    stop_container
}

engine_preflight() {
    CURRENT_CONTAINER="ploof-preflight-$$-$((CASE_COUNTER += 1))"
    if ! docker run -d --name "$CURRENT_CONTAINER" --pull never \
        --platform linux/amd64 \
        --add-host host.docker.internal:host-gateway \
        "$CADDY_IMAGE" caddy version >/dev/null; then
        return 1
    fi
    local status
    status=$(docker wait "$CURRENT_CONTAINER") || return 1
    docker rm -f "$CURRENT_CONTAINER" >/dev/null 2>&1 || return 1
    CURRENT_CONTAINER=""
    [[ $status == 0 ]]
}

proxy_prerequisites() {
    command -v docker >/dev/null || unavailable "docker CLI is unavailable"
    docker info >/dev/null 2>&1 || unavailable "docker daemon is unavailable"
    docker image inspect "$CADDY_IMAGE" >/dev/null 2>&1 || unavailable \
        "pinned Caddy image is not cached; run: docker pull $CADDY_IMAGE"
    docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1 || unavailable \
        "pinned nginx image is not cached; run: docker pull $NGINX_IMAGE"
    if ! engine_preflight; then
        unavailable "docker host-gateway or linux/amd64 execution is unavailable"
    fi
}

command -v awk >/dev/null || unavailable "awk is unavailable"
command -v curl >/dev/null || unavailable "curl is unavailable"
command -v gzip >/dev/null || unavailable "gzip is unavailable"
command -v wc >/dev/null || unavailable "wc is unavailable"
prepare_fixtures
for index in "${!ORIGINS[@]}"; do
    [[ -x ${ORIGINS[$index]} ]] || die "missing origin: ${ORIGINS[$index]}"
    run_direct "${ORIGINS[$index]}" "${MODES[$index]}"
done

proxy_prerequisites
validate_configs

for index in "${!ORIGINS[@]}"; do
    run_caddy "${ORIGINS[$index]}" "${MODES[$index]}" \
        Caddyfile.x_forwarded x-forwarded caddy-x-forwarded
    run_nginx "${ORIGINS[$index]}" "${MODES[$index]}"
    run_caddy "${ORIGINS[$index]}" "${MODES[$index]}" \
        Caddyfile.proxy_v2 proxy-v2-x-forwarded caddy-proxy-v2-x-forwarded
done

[[ $TOPOLOGY_CASES == 12 ]] || die "expected 12 topology runs, got $TOPOLOGY_CASES"
[[ $HTTP_CASES == 180 ]] || die "expected 180 HTTP cases, got $HTTP_CASES"
echo "PASS proxy interop: 12 topology runs, 180 HTTP cases"
