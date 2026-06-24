#!/bin/bash
set -e

[ -n "${DEBUG+x}" ] && set -x

OVPN_DATA=basic-data-otp
CLIENT=travis-client
IMG=kylemanna/openvpn
OTP_USER=otp
CLIENT_DIR="$(readlink -f "$(dirname "$BASH_SOURCE")/../../client")"

# Function to fail
abort() { cat <<< "$@" 1>&2; exit 1; }

ip addr ls
SERV_IP=$(ip -4 -o addr show scope global  | awk '{print $4}' | sed -e 's:/.*::' | head -n1)
# Configure server with two factor authentication
docker run -v $OVPN_DATA:/etc/openvpn --rm $IMG ovpn_genconfig -u udp://$SERV_IP -2

# Ensure reneg-sec 0 in server config when two factor is enabled
docker run -v $OVPN_DATA:/etc/openvpn --rm $IMG cat /etc/openvpn/openvpn.conf | grep 'reneg-sec 0' || abort 'reneg-sec not set to 0 in server config'

# nopass is insecure
docker run -v $OVPN_DATA:/etc/openvpn --rm -i -e "EASYRSA_BATCH=1" -e "EASYRSA_REQ_CN=Travis-CI Test CA" $IMG ovpn_initpki nopass

docker run -v $OVPN_DATA:/etc/openvpn --rm -i -e "EASYRSA_BATCH=1" $IMG easyrsa build-client-full $CLIENT nopass

# Generate OTP credentials for the user. ovpn_otp_user runs google-authenticator,
# which only renders the scannable QR code to an interactive TTY and (as of
# google-authenticator 1.x) no longer prints the deprecated Google Charts URL.
# CI runs without a TTY, so successful enrollment is verified via the secret key
# and emergency scratch codes below rather than a QR/chart artifact.
docker run -v $OVPN_DATA:/etc/openvpn --rm -i $IMG ovpn_otp_user $OTP_USER | tee $CLIENT_DIR/qrcode.txt
grep 'Your new secret key is:' $CLIENT_DIR/qrcode.txt || abort 'Secret key is missing'
# Extract an emergency code from textual output, grepping for line and trimming spaces
OTP_TOKEN=$(grep -A1 'Your emergency scratch codes are' $CLIENT_DIR/qrcode.txt | tail -1 | tr -d '[[:space:]]')
# Token should be present
if [ -z $OTP_TOKEN ]; then
  abort "QR Emergency Code not detected"
fi

# Store authentication credentials in config file and tell openvpn to use them
echo -e "$OTP_USER\n$OTP_TOKEN" > $CLIENT_DIR/credentials.txt

# Override the auth-user-pass directive to use a credentials file
docker run -v $OVPN_DATA:/etc/openvpn --rm $IMG ovpn_getclient $CLIENT | sed 's/auth-user-pass/auth-user-pass \/client\/credentials.txt/' | tee $CLIENT_DIR/config.ovpn

# Ensure reneg-sec 0 in client config when two factor is enabled
grep 'reneg-sec 0' $CLIENT_DIR/config.ovpn || abort 'reneg-sec not set to 0 in client config'

#
# Fire up the server
#
trap "{ jobs -p | xargs -r kill; wait; }" EXIT
docker run --name "ovpn-test" -v $OVPN_DATA:/etc/openvpn --rm --cap-add=NET_ADMIN $IMG &

for i in $(seq 10); do
    SERV_IP_INTERNAL=$(docker inspect --format '{{ range .NetworkSettings.Networks }}{{ .IPAddress }}{{ end }}' "ovpn-test" 2>/dev/null || true)
    test -n "$SERV_IP_INTERNAL" && break
    sleep 0.1
done
sed -i -e s:$SERV_IP:$SERV_IP_INTERNAL:g $CLIENT_DIR/config.ovpn

#
# Fire up a client in a container since openvpn is disallowed by Travis-CI
docker run --rm --cap-add=NET_ADMIN --volume $CLIENT_DIR:/client -e DEBUG $IMG /client/wait-for-connect.sh

#
# Celebrate
#
cat <<EOF
 ___________
< it worked >
 -----------
        \   ^__^
         \  (oo)\_______
            (__)\       )\/\\
                ||----w |
                ||     ||
EOF
