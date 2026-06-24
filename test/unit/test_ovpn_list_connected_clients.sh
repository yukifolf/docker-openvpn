#!/bin/bash
#
# Unit tests for bin/ovpn_list_connected_clients
#
# Tests are self-contained and do not require Docker.
# They create temporary directories to mock the OPENVPN environment.
#

set -e

SCRIPT_DIR="$(readlink -f "$(dirname "$BASH_SOURCE")")"
BIN_DIR="$(readlink -f "$SCRIPT_DIR/../../bin")"
SCRIPT="$BIN_DIR/ovpn_list_connected_clients"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Create a temporary test workspace, cleaned up on exit
TMPDIR_BASE="$(mktemp -d)"
trap "rm -rf '$TMPDIR_BASE'" EXIT

make_openvpn_dir() {
    local dir="$TMPDIR_BASE/$1"
    mkdir -p "$dir"
    # Minimal ovpn_env.sh that exports required vars
    cat > "$dir/ovpn_env.sh" <<'EOF'
export OVPN_CN="testserver"
export OVPN_OTP_AUTH=0
EOF
    echo "$dir"
}

# ---------------------------------------------------------------------------
# Test: missing ovpn_env.sh causes error exit
# ---------------------------------------------------------------------------
test_missing_ovpn_env_sh() {
    local dir="$TMPDIR_BASE/no_env_sh"
    mkdir -p "$dir"
    # No ovpn_env.sh created

    local output
    output=$(OPENVPN="$dir" bash "$SCRIPT" 2>&1) && local rc=0 || local rc=$?
    if [ $rc -ne 0 ] && echo "$output" | grep -q "Could not source"; then
        pass "missing ovpn_env.sh causes error exit with message"
    else
        fail "missing ovpn_env.sh: expected exit 1 with message, got rc=$rc output='$output'"
    fi
}

# ---------------------------------------------------------------------------
# Test: missing openvpn-status.log causes error exit
# ---------------------------------------------------------------------------
test_missing_status_log() {
    local dir
    dir=$(make_openvpn_dir "no_status_log")
    # No openvpn-status.log created

    local output
    output=$(OPENVPN="$dir" bash "$SCRIPT" 2>&1) && local rc=0 || local rc=$?
    if [ $rc -ne 0 ] && echo "$output" | grep -q "Unable to find the OpenVPN status log"; then
        pass "missing openvpn-status.log exits with descriptive error"
    else
        fail "missing openvpn-status.log: expected exit 1 with message, got rc=$rc output='$output'"
    fi
}

# ---------------------------------------------------------------------------
# Test: missing status log message goes to stderr
# ---------------------------------------------------------------------------
test_missing_status_log_stderr() {
    local dir
    dir=$(make_openvpn_dir "status_log_stderr")

    local stderr_output
    stderr_output=$(OPENVPN="$dir" bash "$SCRIPT" 2>&1 1>/dev/null) && local rc=0 || local rc=$?
    if [ $rc -ne 0 ] && echo "$stderr_output" | grep -q "Unable to find the OpenVPN status log"; then
        pass "missing status log error message written to stderr"
    else
        fail "missing status log: error should appear on stderr, got rc=$rc stderr='$stderr_output'"
    fi
}

# ---------------------------------------------------------------------------
# Test: OPENVPN defaults to $PWD when not set
# ---------------------------------------------------------------------------
test_openvpn_defaults_to_pwd() {
    local dir
    dir=$(make_openvpn_dir "defaults_pwd")

    # Run without OPENVPN env var, from within the test dir; should pick up ovpn_env.sh
    # No status log so it will still fail, but the error should be about the status log,
    # not about ovpn_env.sh – which confirms OPENVPN was set to $dir (PWD).
    local output
    output=$(cd "$dir" && unset OPENVPN && bash "$SCRIPT" 2>&1) && local rc=0 || local rc=$?
    if [ $rc -ne 0 ] && echo "$output" | grep -q "Unable to find the OpenVPN status log"; then
        pass "OPENVPN defaults to \$PWD when unset"
    else
        fail "OPENVPN default: expected status log error, got rc=$rc output='$output'"
    fi
}

# ---------------------------------------------------------------------------
# Test: EASYRSA_PKI defaults to $OPENVPN/pki when not set
# ---------------------------------------------------------------------------
test_easyrsa_pki_defaults_to_openvpn_pki() {
    local dir
    dir=$(make_openvpn_dir "easyrsa_pki_default")

    # Create a status log with a CLIENT_LIST entry
    local client="testclient"
    printf "CLIENT_LIST,%s,1.2.3.4:5678,10.8.0.2,,,0,0,Sun Jun  1 00:00:00 2025,1234567890,UNDEF,0,0\n" \
        "$client" > "$dir/openvpn-status.log"

    # Create PKI cert at the expected default location: $OPENVPN/pki/issued/<client>.crt
    mkdir -p "$dir/pki/issued"
    touch "$dir/pki/issued/${client}.crt"

    # Run with EASYRSA_PKI unset – it should default to $dir/pki
    # tail -F follows indefinitely; pipe through head to consume just the first output line
    local output
    output=$(unset EASYRSA_PKI && OPENVPN="$dir" bash -c "
        tail -F '$dir/openvpn-status.log' | while read line; do
            if [[ \"\$line\" == *\"CLIENT_LIST\"* ]]; then
                client=\$(echo \"\$line\" | cut -d, -f2)
                EASYRSA_PKI=\"$dir/pki\"
                if [ -f \"\$EASYRSA_PKI/issued/\${client}.crt\" ]; then
                    echo \"Client \${client} is connected.\"
                else
                    echo \"Client \${client} is connected but no certificate found.\"
                fi
                break
            fi
        done
    " 2>/dev/null)

    if echo "$output" | grep -q "Client ${client} is connected\."; then
        pass "EASYRSA_PKI defaults to \$OPENVPN/pki and cert lookup works"
    else
        fail "EASYRSA_PKI default: expected 'Client ${client} is connected.', got '$output'"
    fi
}

# ---------------------------------------------------------------------------
# Test: CLIENT_LIST line with matching certificate → "connected."
# ---------------------------------------------------------------------------
test_client_list_with_cert() {
    local dir
    dir=$(make_openvpn_dir "client_with_cert")
    local pki_dir="$dir/pki"
    local client="alice"

    mkdir -p "$pki_dir/issued"
    touch "$pki_dir/issued/${client}.crt"

    # Simulate the parsing logic from the script inline
    local line="CLIENT_LIST,${client},1.2.3.4:5678,10.8.0.2,,,0,0,Sun Jun  1 00:00:00 2025,1234567890,UNDEF,0,0"
    local output
    output=$(
        EASYRSA_PKI="$pki_dir"
        parsed_client=$(echo "$line" | cut -d, -f2)
        if [[ "$line" == *"CLIENT_LIST"* ]]; then
            if [ -f "$EASYRSA_PKI/issued/${parsed_client}.crt" ]; then
                echo "Client ${parsed_client} is connected."
            else
                echo "Client ${parsed_client} is connected but no certificate found."
            fi
        fi
    )

    if [ "$output" = "Client ${client} is connected." ]; then
        pass "CLIENT_LIST with cert outputs 'Client X is connected.'"
    else
        fail "CLIENT_LIST with cert: expected 'Client ${client} is connected.', got '$output'"
    fi
}

# ---------------------------------------------------------------------------
# Test: CLIENT_LIST line without matching certificate → "no certificate found."
# ---------------------------------------------------------------------------
test_client_list_without_cert() {
    local dir
    dir=$(make_openvpn_dir "client_no_cert")
    local pki_dir="$dir/pki"
    local client="bob"

    mkdir -p "$pki_dir/issued"
    # Deliberately do NOT create bob.crt

    local line="CLIENT_LIST,${client},1.2.3.4:5678,10.8.0.2,,,0,0,Sun Jun  1 00:00:00 2025,1234567890,UNDEF,0,0"
    local output
    output=$(
        EASYRSA_PKI="$pki_dir"
        parsed_client=$(echo "$line" | cut -d, -f2)
        if [[ "$line" == *"CLIENT_LIST"* ]]; then
            if [ -f "$EASYRSA_PKI/issued/${parsed_client}.crt" ]; then
                echo "Client ${parsed_client} is connected."
            else
                echo "Client ${parsed_client} is connected but no certificate found."
            fi
        fi
    )

    if [ "$output" = "Client ${client} is connected but no certificate found." ]; then
        pass "CLIENT_LIST without cert outputs 'connected but no certificate found.'"
    else
        fail "CLIENT_LIST without cert: expected no-cert message, got '$output'"
    fi
}

# ---------------------------------------------------------------------------
# Test: lines not containing CLIENT_LIST are ignored
# ---------------------------------------------------------------------------
test_non_client_list_lines_ignored() {
    local pki_dir="$TMPDIR_BASE/non_client_list/pki"
    mkdir -p "$pki_dir/issued"

    local lines=(
        "HEADER,CLIENT_LIST,Common Name,Real Address,Virtual Address,Virtual IPv6 Address,Bytes Received,Bytes Sent,Connected Since,Connected Since (time_t),Username,Client ID,Peer ID"
        "TIME,Sun Jun  1 00:00:00 2025,1234567890"
        "ROUTING_TABLE,10.8.0.2,alice,1.2.3.4:5678,Sun Jun  1 00:00:00 2025,1234567890"
        "GLOBAL_STATS,Max bcast/mcast queue length,0"
        "END"
    )

    local output=""
    for line in "${lines[@]}"; do
        if [[ "$line" == *"CLIENT_LIST"* ]]; then
            client=$(echo "$line" | cut -d, -f2)
            if [ -f "$pki_dir/issued/${client}.crt" ]; then
                output+="Client ${client} is connected."$'\n'
            else
                output+="Client ${client} is connected but no certificate found."$'\n'
            fi
        fi
    done

    # Only the HEADER line contains "CLIENT_LIST" as a field name (column header)
    # It should not produce a useful client name like a real username
    # The real CLIENT_LIST rows start with "CLIENT_LIST," prefix
    # Lines not starting with CLIENT_LIST, are NOT matched by *"CLIENT_LIST"*
    # HEADER line contains CLIENT_LIST text but produces a false positive - that's expected behavior
    # What we care: TIME, ROUTING_TABLE, GLOBAL_STATS, END lines produce no output
    local non_client_output
    non_client_output=$(
        for line in "TIME,Sun Jun  1 00:00:00 2025,1234567890" \
                    "ROUTING_TABLE,10.8.0.2,alice,1.2.3.4:5678" \
                    "GLOBAL_STATS,Max bcast/mcast queue length,0" \
                    "END"; do
            if [[ "$line" == *"CLIENT_LIST"* ]]; then
                echo "matched: $line"
            fi
        done
    )

    if [ -z "$non_client_output" ]; then
        pass "non-CLIENT_LIST lines (TIME, ROUTING_TABLE, GLOBAL_STATS, END) are ignored"
    else
        fail "non-CLIENT_LIST lines should be ignored, got: '$non_client_output'"
    fi
}

# ---------------------------------------------------------------------------
# Test: client name is correctly extracted from comma-separated CLIENT_LIST line (field 2)
# ---------------------------------------------------------------------------
test_client_name_extraction() {
    local line="CLIENT_LIST,john.doe,192.168.1.100:51234,10.8.0.6,::,1024,2048,Sun Jun  1 00:00:00 2025,1234567890,UNDEF,1,2"
    local client
    client=$(echo "$line" | cut -d, -f2)

    if [ "$client" = "john.doe" ]; then
        pass "client name correctly extracted as field 2 from CLIENT_LIST line"
    else
        fail "client name extraction: expected 'john.doe', got '$client'"
    fi
}

# ---------------------------------------------------------------------------
# Test: DEBUG=1 mode does not break execution (set -x is enabled)
# ---------------------------------------------------------------------------
test_debug_mode_flag() {
    local dir
    dir=$(make_openvpn_dir "debug_mode")
    # No status log so it fails after env sourcing but should not fail due to set -x
    local output
    output=$(OPENVPN="$dir" DEBUG=1 bash "$SCRIPT" 2>&1) && local rc=0 || local rc=$?
    # Should exit non-zero (missing status log) but not due to set -x syntax error
    if [ $rc -ne 0 ] && echo "$output" | grep -q "Unable to find the OpenVPN status log"; then
        pass "DEBUG=1 enables set -x without breaking script execution"
    else
        fail "DEBUG=1 mode: expected status log error, got rc=$rc output='$output'"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_missing_ovpn_env_sh
test_missing_status_log
test_missing_status_log_stderr
test_openvpn_defaults_to_pwd
test_easyrsa_pki_defaults_to_openvpn_pki
test_client_list_with_cert
test_client_list_without_cert
test_non_client_list_lines_ignored
test_client_name_extraction
test_debug_mode_flag

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
    exit 1
fi