#!/bin/sh
# Generate a local development certificate for the datastar.zig example apps.
#
# This is a *developer convenience* and deliberately lives outside src/. The
# library itself never generates certificates: a library that invents its own
# cert when it cannot find one makes it far too easy to ship a server whose TLS
# nobody actually configured. See Config.tls in src/server.zig.
#
#   sh tools/make_devcert.sh [output-dir] [extra-name ...]
#
# Examples:
#   sh tools/make_devcert.sh
#   sh tools/make_devcert.sh devcert 192.168.1.13 devbox.local
#
# Run this before starting an example with --tls, or pass your own certificate.
# The library never generates or falls back to a certificate of its own.
#
# The SAN list is the part that matters. Browsers ignore the legacy Common Name
# and match on subjectAltName only, and a SAN *mismatch* is a hard failure — no
# "proceed anyway" link, unlike an untrusted issuer. So a server reached from
# another machine ("mini2.local:8088") needs that name in the list.
set -e

DIR=${1:-devcert}
shift 2>/dev/null || true

HOST=$(hostname)
mkdir -p "$DIR"

# Start with localhost and the loopback addresses.
SAN="DNS:localhost"
# Add this machine's own names. `hostname` may return the FQDN ("mini2.local");
# include both the full name and its short form.
if [ "$HOST" != "localhost" ]; then
  SAN="$SAN,DNS:$HOST"
  case "$HOST" in
    *.local) SAN="$SAN,DNS:${HOST%.local}" ;;
    *)       SAN="$SAN,DNS:$HOST.local" ;;
  esac
fi
SAN="$SAN,IP:127.0.0.1,IP:::1"

# Add any names given on the command line.
for NAME in "$@"; do
  case "$NAME" in
    # Anything that parses as an address goes in as an IP.
    *[0-9].[0-9]*.[0-9]*.[0-9]*|*:*) SAN="$SAN,IP:$NAME" ;;
    *)                                     SAN="$SAN,DNS:$NAME" ;;
  esac
done

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
  -subj "/CN=localhost" \
  -addext "subjectAltName=$SAN" 2>/dev/null

chmod 600 "$DIR/key.pem"

echo "devcert written to $DIR/"
echo "  subjectAltName=$SAN"
echo
echo "Browsers will still warn about the self-signed issuer. That is expected"
echo "and, unlike a SAN mismatch, can be clicked through or silenced by trusting"
echo "$DIR/cert.pem in your OS keychain."
