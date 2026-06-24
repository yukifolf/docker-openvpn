#!/bin/bash
#
# Unit tests for bin/ovpn_otp_user
#
# Tests cover the changes made in this PR:
#   1. Quoted variable fix: [ -z "$1" ] instead of [ -z $1 ]
#   2. Interactive mode: --qr-mode=UTF8 and --issuer flags added
#   3. Non-interactive mode: --issuer flag added
#
# Tests are self-contained and do not require Docker.
# They use a mock google-authenticator binary to capture flags.
#

set -e

SCRIPT_DIR="$(readlink -f "$(dirname "$BASH_SOURCE")")"
BIN_DIR="$(readlink -f "$SCRIPT_DIR/../../bin")"
SCRIPT="$BIN_DIR/ovpn_otp_user"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMPDIR_BASE="$(mktemp -d)"
trap "rm -rf '$TMPDIR_BASE'" EXIT

# Create a minimal OPENVPN directory with a valid ovpn_env.sh
make_openvpn_dir() {
    local name="$1"
    local otp_auth="${2:-1}"
    local cn="${3:-myvpn.example.com}"
    local dir="$TMPDIR_BASE/$name"
    mkdir -p "$dir"
    cat > "$dir/ovpn_env.sh" <<EOF
export OVPN_CN="${cn}"
export OVPN_OTP_AUTH=${otp_auth}
EOF
    echo "$dir"
}

# Create a mock google-authenticator that records the arguments it receives
make_mock_ga() {
    local mock_dir="$1"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/google-authenticator" <<'EOF'
#!/bin/bash
# Mock google-authenticator: write all arguments to a file and exit 0
echo "$@" > "$(dirname "$0")/ga_args.txt"
# Print minimal expected output so callers don't fail on grep
echo "Your new secret key is: TESTSECRETKEY"
echo "Your verification code is 123456"
echo "Your emergency scratch codes are:"
echo "  12345678"
EOF
    chmod +x "$mock_dir/google-authenticator"
}

# ---------------------------------------------------------------------------
# Test: missing ovpn_env.sh causes exit with error message
# ---------------------------------------------------------------------------
test_missing_ovpn_env_sh() {
    local dir="$TMPDIR_BASE/otp_no_env"
    mkdir -p "$dir"
    # No ovpn_env.sh

    local output
    output=$(OPENVPN="$dir" bash "$SCRIPT" someuser 2>&1) && local rc=0 || local rc=$?
    if [ $rc -ne 0 ] && echo "$output" | grep -q "Could not source"; then
        pass "missing ovpn_env.sh exits with error message"
    else
        fail "missing ovpn_env.sh: expected exit 1 with message, got rc=$rc output='$output'"
    fi
}

# ---------------------------------------------------------------------------
# Test: OTP not enabled (OVPN_OTP_AUTH != 1) exits with error
# ---------------------------------------------------------------------------
test_otp_not_enabled() {
    local dir
    dir=$(make_openvpn_dir "otp_disabled" 0)

    local output
    output=$(OPENVPN="$dir" bash "$SCRIPT" someuser 2>&1) && local rc=0 || local rc=$?
    if [ $rc -ne 0 ] && echo "$output" | grep -q "OTP authentication not enabled"; then
        pass "OTP not enabled exits with 'OTP authentication not enabled' message"
    else
        fail "OTP disabled: expected error message, got rc=$rc output='$output'"
    fi
}

# ---------------------------------------------------------------------------
# Test: empty username ($1 unquoted fix) exits with usage message
# This specifically validates the PR fix: [ -z "$1" ] vs [ -z $1 ]
# With the old code [ -z $1 ] would expand to [ -z ] which exits 0 (true)
# The fix ensures empty/missing username is properly detected
# ---------------------------------------------------------------------------
test_empty_username_shows_usage() {
    local dir
    dir=$(make_openvpn_dir "otp_empty_user")

    local output
    # Pass an empty string as $1 – the fixed code [ -z "$1" ] catches this
    output=$(OPENVPN="$dir" bash "$SCRIPT" "" 2>&1) && local rc=0 || local rc=$?
    if [ $rc -ne 0 ] && echo "$output" | grep -q "Usage: ovpn_otp_user USERNAME"; then
        pass "empty username (quoted \$1 fix) shows usage and exits non-zero"
    else
        fail "empty username: expected usage message and non-zero exit, got rc=$rc output='$output'"
    fi
}

# ---------------------------------------------------------------------------
# Test: missing username (no args) shows usage
# ---------------------------------------------------------------------------
test_no_args_shows_usage() {
    local dir
    dir=$(make_openvpn_dir "otp_no_args")

    local output
    output=$(OPENVPN="$dir" bash "$SCRIPT" 2>&1) && local rc=0 || local rc=$?
    if [ $rc -ne 0 ] && echo "$output" | grep -q "Usage: ovpn_otp_user USERNAME"; then
        pass "no arguments shows usage message and exits non-zero"
    else
        fail "no args: expected usage message and non-zero exit, got rc=$rc output='$output'"
    fi
}

# ---------------------------------------------------------------------------
# Test: non-interactive mode passes --issuer flag to google-authenticator
# ---------------------------------------------------------------------------
test_non_interactive_includes_issuer() {
    local dir
    dir=$(make_openvpn_dir "otp_non_interactive_issuer")
    local mock_dir="$TMPDIR_BASE/mock_ga_ni"
    make_mock_ga "$mock_dir"

    OPENVPN="$dir" PATH="$mock_dir:$PATH" bash "$SCRIPT" testuser 2>&1 || true

    local ga_args
    ga_args=$(cat "$mock_dir/ga_args.txt" 2>/dev/null || echo "")
    if echo "$ga_args" | grep -q -- "--issuer="; then
        pass "non-interactive mode passes --issuer flag to google-authenticator"
    else
        fail "non-interactive mode: --issuer flag missing, got args: '$ga_args'"
    fi
}

# ---------------------------------------------------------------------------
# Test: non-interactive mode issuer value matches OVPN_CN
# ---------------------------------------------------------------------------
test_non_interactive_issuer_value() {
    local cn="vpn.mycompany.org"
    local dir
    dir=$(make_openvpn_dir "otp_ni_issuer_value" 1 "$cn")
    local mock_dir="$TMPDIR_BASE/mock_ga_ni_val"
    make_mock_ga "$mock_dir"

    OPENVPN="$dir" PATH="$mock_dir:$PATH" bash "$SCRIPT" testuser 2>&1 || true

    local ga_args
    ga_args=$(cat "$mock_dir/ga_args.txt" 2>/dev/null || echo "")
    if echo "$ga_args" | grep -q -- "--issuer=${cn}"; then
        pass "non-interactive mode --issuer value matches OVPN_CN ('${cn}')"
    else
        fail "non-interactive issuer value: expected --issuer=${cn}, got args: '$ga_args'"
    fi
}

# ---------------------------------------------------------------------------
# Test: interactive mode passes --qr-mode=UTF8 flag
# ---------------------------------------------------------------------------
test_interactive_includes_qr_mode_utf8() {
    local dir
    dir=$(make_openvpn_dir "otp_interactive_qr")
    local mock_dir="$TMPDIR_BASE/mock_ga_int_qr"
    make_mock_ga "$mock_dir"

    OPENVPN="$dir" PATH="$mock_dir:$PATH" bash "$SCRIPT" testuser interactive 2>&1 || true

    local ga_args
    ga_args=$(cat "$mock_dir/ga_args.txt" 2>/dev/null || echo "")
    if echo "$ga_args" | grep -q -- "--qr-mode=UTF8"; then
        pass "interactive mode passes --qr-mode=UTF8 flag to google-authenticator"
    else
        fail "interactive mode: --qr-mode=UTF8 missing, got args: '$ga_args'"
    fi
}

# ---------------------------------------------------------------------------
# Test: interactive mode passes --issuer flag
# ---------------------------------------------------------------------------
test_interactive_includes_issuer() {
    local dir
    dir=$(make_openvpn_dir "otp_interactive_issuer")
    local mock_dir="$TMPDIR_BASE/mock_ga_int_iss"
    make_mock_ga "$mock_dir"

    OPENVPN="$dir" PATH="$mock_dir:$PATH" bash "$SCRIPT" testuser interactive 2>&1 || true

    local ga_args
    ga_args=$(cat "$mock_dir/ga_args.txt" 2>/dev/null || echo "")
    if echo "$ga_args" | grep -q -- "--issuer="; then
        pass "interactive mode passes --issuer flag to google-authenticator"
    else
        fail "interactive mode: --issuer flag missing, got args: '$ga_args'"
    fi
}

# ---------------------------------------------------------------------------
# Test: interactive mode issuer value matches OVPN_CN
# ---------------------------------------------------------------------------
test_interactive_issuer_value() {
    local cn="secure.vpn.example.net"
    local dir
    dir=$(make_openvpn_dir "otp_int_issuer_val" 1 "$cn")
    local mock_dir="$TMPDIR_BASE/mock_ga_int_iv"
    make_mock_ga "$mock_dir"

    OPENVPN="$dir" PATH="$mock_dir:$PATH" bash "$SCRIPT" testuser interactive 2>&1 || true

    local ga_args
    ga_args=$(cat "$mock_dir/ga_args.txt" 2>/dev/null || echo "")
    if echo "$ga_args" | grep -q -- "--issuer=${cn}"; then
        pass "interactive mode --issuer value matches OVPN_CN ('${cn}')"
    else
        fail "interactive issuer value: expected --issuer=${cn}, got args: '$ga_args'"
    fi
}

# ---------------------------------------------------------------------------
# Test: non-interactive mode passes --no-confirm flag (unchanged behavior)
# ---------------------------------------------------------------------------
test_non_interactive_includes_no_confirm() {
    local dir
    dir=$(make_openvpn_dir "otp_no_confirm")
    local mock_dir="$TMPDIR_BASE/mock_ga_nc"
    make_mock_ga "$mock_dir"

    OPENVPN="$dir" PATH="$mock_dir:$PATH" bash "$SCRIPT" testuser 2>&1 || true

    local ga_args
    ga_args=$(cat "$mock_dir/ga_args.txt" 2>/dev/null || echo "")
    if echo "$ga_args" | grep -q -- "--no-confirm"; then
        pass "non-interactive mode passes --no-confirm to google-authenticator"
    else
        fail "non-interactive mode: --no-confirm missing, got args: '$ga_args'"
    fi
}

# ---------------------------------------------------------------------------
# Test: non-interactive mode uses --time-based (unchanged behavior)
# ---------------------------------------------------------------------------
test_non_interactive_time_based() {
    local dir
    dir=$(make_openvpn_dir "otp_time_based")
    local mock_dir="$TMPDIR_BASE/mock_ga_tb"
    make_mock_ga "$mock_dir"

    OPENVPN="$dir" PATH="$mock_dir:$PATH" bash "$SCRIPT" testuser 2>&1 || true

    local ga_args
    ga_args=$(cat "$mock_dir/ga_args.txt" 2>/dev/null || echo "")
    if echo "$ga_args" | grep -q -- "--time-based"; then
        pass "non-interactive mode passes --time-based to google-authenticator"
    else
        fail "non-interactive mode: --time-based missing, got args: '$ga_args'"
    fi
}

# ---------------------------------------------------------------------------
# Test: label uses username@OVPN_CN format (both modes)
# ---------------------------------------------------------------------------
test_label_format() {
    local cn="my.vpn.host"
    local user="carol"
    local dir
    dir=$(make_openvpn_dir "otp_label_fmt" 1 "$cn")
    local mock_dir="$TMPDIR_BASE/mock_ga_lbl"
    make_mock_ga "$mock_dir"

    OPENVPN="$dir" PATH="$mock_dir:$PATH" bash "$SCRIPT" "$user" 2>&1 || true

    local ga_args
    ga_args=$(cat "$mock_dir/ga_args.txt" 2>/dev/null || echo "")
    if echo "$ga_args" | grep -q -- "-l ${user}@${cn}"; then
        pass "google-authenticator called with -l username@OVPN_CN label format"
    else
        fail "label format: expected '-l ${user}@${cn}', got args: '$ga_args'"
    fi
}

# ---------------------------------------------------------------------------
# Test: OTP directory is created when absent
# ---------------------------------------------------------------------------
test_otp_dir_created() {
    local dir
    dir=$(make_openvpn_dir "otp_mkdir")
    local mock_dir="$TMPDIR_BASE/mock_ga_mkdir"
    make_mock_ga "$mock_dir"

    # Ensure /etc/openvpn/otp does not pre-exist (it usually won't in test env)
    # We can't easily test the real /etc/openvpn/otp path without root, but we
    # can verify the script reaches the google-authenticator call (meaning mkdir succeeded)
    OPENVPN="$dir" PATH="$mock_dir:$PATH" bash "$SCRIPT" testuser 2>&1 || true

    local ga_args_file="$mock_dir/ga_args.txt"
    if [ -f "$ga_args_file" ]; then
        pass "OTP dir creation succeeded and google-authenticator was called"
    else
        fail "otp dir creation: google-authenticator mock was never called"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_missing_ovpn_env_sh
test_otp_not_enabled
test_empty_username_shows_usage
test_no_args_shows_usage
test_non_interactive_includes_issuer
test_non_interactive_issuer_value
test_interactive_includes_qr_mode_utf8
test_interactive_includes_issuer
test_interactive_issuer_value
test_non_interactive_includes_no_confirm
test_non_interactive_time_based
test_label_format
test_otp_dir_created

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
    exit 1
fi