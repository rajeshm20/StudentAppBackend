#!/usr/bin/env bash
#
# scripts/renew-dev-certs.sh
# Automate Self-Signed Certificate Generation and Renewal for Local Development
#
# Usage:
#   ./scripts/renew-dev-certs.sh [OPTIONS]
#
# Options:
#   --check-only      Check certificate validity without renewing (exit 0 if valid, 1 if expired/missing/expiring)
#   --force           Force certificate regeneration even if currently valid
#   --days <N>        Certificate validity duration in days (default: 365)
#   --threshold <N>   Expiration threshold in days to trigger renewal (default: 30)
#   --cert-dir <DIR>  Directory to store certificates (default: certs)
#   --san <SANS>      Comma-separated Subject Alternative Names (default: DNS:localhost,IP:127.0.0.1,IP:::1)
#   -h, --help        Display this help message and exit
#

set -euo pipefail

# Defaults
CERT_DIR="certs"
DAYS=365
THRESHOLD_DAYS=30
SANS="DNS:localhost,IP:127.0.0.1,IP:::1"
CHECK_ONLY=false
FORCE=false

# Print usage
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Automate self-signed certificate generation and renewal for local development.

Options:
  --check-only       Check certificate validity without regenerating (exit 0 if valid, 1 if renewal needed)
  --force            Force certificate regeneration even if currently valid
  --days <N>         Certificate validity in days (default: 365)
  --threshold <N>    Threshold in days before expiration to trigger renewal (default: 30)
  --cert-dir <DIR>   Target directory for certificates (default: certs)
  --san <SANS>       Subject Alternative Names (default: DNS:localhost,IP:127.0.0.1,IP:::1)
  -h, --help         Show this help message and exit
EOF
    exit 0
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --days)
            DAYS="$2"
            shift 2
            ;;
        --threshold)
            THRESHOLD_DAYS="$2"
            shift 2
            ;;
        --cert-dir)
            CERT_DIR="$2"
            shift 2
            ;;
        --san)
            SANS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown argument: $1" >&2
            usage
            ;;
    esac
done

# Verify openssl is available
if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: 'openssl' command is required but not found in PATH." >&2
    exit 127
fi

CERT_FILE="$CERT_DIR/cert.pem"
KEY_FILE="$CERT_DIR/key.pem"
P12_FILE="$CERT_DIR/localhost.p12"

THRESHOLD_SECONDS=$((THRESHOLD_DAYS * 86400))

# Check certificate health
check_certificate() {
    if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
        echo "Status: MISSING — Certificate or private key missing at '$CERT_DIR'."
        return 1
    fi

    # Check if certificate is already expired
    if ! openssl x509 -in "$CERT_FILE" -checkend 0 -noout >/dev/null 2>&1; then
        local expiry_date
        expiry_date=$(openssl x509 -in "$CERT_FILE" -enddate -noout | cut -d= -f2)
        echo "Status: EXPIRED — Certificate expired on $expiry_date."
        return 1
    fi

    # Check if certificate is expiring within threshold
    if ! openssl x509 -in "$CERT_FILE" -checkend "$THRESHOLD_SECONDS" -noout >/dev/null 2>&1; then
        local expiry_date
        expiry_date=$(openssl x509 -in "$CERT_FILE" -enddate -noout | cut -d= -f2)
        echo "Status: EXPIRING_SOON — Certificate expires within $THRESHOLD_DAYS days (on $expiry_date)."
        return 1
    fi

    local expiry_date
    expiry_date=$(openssl x509 -in "$CERT_FILE" -enddate -noout | cut -d= -f2)
    echo "Status: VALID — Certificate is healthy and valid until $expiry_date."
    return 0
}

# If check-only flag is set, run check and exit with appropriate code
if [[ "$CHECK_ONLY" == "true" ]]; then
    if check_certificate; then
        exit 0
    else
        exit 1
    fi
fi

# Determine if renewal is required
RENEWAL_REQUIRED=false

if [[ "$FORCE" == "true" ]]; then
    echo "Renewal reason: --force flag supplied."
    RENEWAL_REQUIRED=true
elif ! check_certificate; then
    RENEWAL_REQUIRED=true
fi

if [[ "$RENEWAL_REQUIRED" == "false" ]]; then
    echo "Certificate renewal skipped: existing certificate is valid for at least $THRESHOLD_DAYS more days."
    echo "Use --force to regenerate immediately if desired."
    exit 0
fi

# Create target directory
mkdir -p "$CERT_DIR"

echo "Generating new self-signed certificate in '$CERT_DIR'..."
echo "  Validity: $DAYS days"
echo "  SANs: $SANS"

# Generate private key and self-signed certificate with Subject Alternative Names
if openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -days "$DAYS" \
    -subj "/CN=localhost" \
    -addext "subjectAltName=$SANS" >/dev/null 2>&1; then
    :
else
    # Fallback for older OpenSSL versions without -addext support
    OPENSSL_CONF=$(mktemp)
    cat > "$OPENSSL_CONF" << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = localhost
[v3_req]
subjectAltName = $SANS
EOF
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days "$DAYS" \
        -config "$OPENSSL_CONF" >/dev/null 2>&1
    rm -f "$OPENSSL_CONF"
fi

# Export PKCS#12 bundle with empty password for macOS Keychain / iOS Simulator trust
openssl pkcs12 -export \
    -out "$P12_FILE" \
    -inkey "$KEY_FILE" \
    -in "$CERT_FILE" \
    -name "Vapor Localhost Cert" \
    -passout pass: >/dev/null 2>&1

# Apply restrictive file permissions
chmod 600 "$KEY_FILE"
chmod 600 "$P12_FILE"
chmod 644 "$CERT_FILE"

EXPIRY=$(openssl x509 -in "$CERT_FILE" -enddate -noout | cut -d= -f2)

echo "Certificate generation successful!"
echo "  Certificate: $CERT_FILE (0644)"
echo "  Private Key: $KEY_FILE (0600)"
echo "  PKCS#12:     $P12_FILE (0600)"
echo "  Valid until: $EXPIRY"
exit 0
