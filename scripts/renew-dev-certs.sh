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
# Default SAN includes localhost, IPv4 loopback (127.0.0.1), and IPv6 loopback (::1).
# Note: "IP:::1" represents OpenSSL's "IP:" prefix concatenated with the IPv6 loopback literal "::1".
SANS="DNS:localhost,IP:127.0.0.1,IP:::1"
P12_PASS=""
CHECK_ONLY=false
FORCE=false

# Temp config file tracker and cleanup trap
OPENSSL_CONF=""
cleanup() {
    if [[ -n "${OPENSSL_CONF:-}" && -f "${OPENSSL_CONF:-}" ]]; then
        rm -f "$OPENSSL_CONF"
    fi
}
trap cleanup EXIT INT TERM

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
  --p12-pass <PASS>  Password for PKCS#12 bundle (default: empty password)
  -h, --help         Show this help message and exit
EOF
    exit 0
}

# Validate each comma-separated SAN token
validate_sans() {
    local raw_sans="$1"
    if [[ -z "$raw_sans" ]]; then
        echo "Error: --san cannot be empty" >&2
        exit 1
    fi

    local IFS=','
    local -a san_tokens
    read -r -a san_tokens <<< "$raw_sans"

    for token in "${san_tokens[@]}"; do
        # Trim leading and trailing whitespace
        local t="${token#"${token%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"

        if [[ -z "$t" ]]; then
            echo "Error: empty SAN token found in '$raw_sans'" >&2
            exit 1
        fi

        if [[ "$t" =~ ^DNS:[A-Za-z0-9.-]+$ ]]; then
            local hostname="${t#DNS:}"
            # Disallow underscores in DNS hostnames (RFC 1035 / RFC 1123)
            if [[ "$hostname" == *"_"* ]]; then
                echo "Error: invalid DNS SAN '$t': underscores are not permitted in DNS hostnames." >&2
                exit 1
            fi
            # Disallow leading or trailing dot or hyphen
            if [[ "$hostname" == .* || "$hostname" == *. || "$hostname" == -* || "$hostname" == *- ]]; then
                echo "Error: invalid DNS SAN '$t': cannot start or end with '.' or '-'." >&2
                exit 1
            fi
        elif [[ "$t" =~ ^IP:([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|[0-9a-fA-F:]+)$ ]]; then
            local ip="${t#IP:}"
            # If IPv4, validate octets <= 255
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                local oIFS="$IFS"
                IFS='.'
                local -a octets
                read -r -a octets <<< "$ip"
                IFS="$oIFS"
                for octet in "${octets[@]}"; do
                    if (( octet > 255 )); then
                        echo "Error: invalid IPv4 address in SAN '$t': octet $octet exceeds 255." >&2
                        exit 1
                    fi
                done
            fi
        else
            echo "Error: invalid SAN token '$t'. Only well-formed 'DNS:<hostname>' and 'IP:<address>' entries are permitted." >&2
            exit 1
        fi
    done
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
            if ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
                echo "Error: --days must be a positive integer" >&2
                exit 1
            fi
            DAYS="$2"
            shift 2
            ;;
        --threshold)
            if ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 0 ]; then
                echo "Error: --threshold must be a non-negative integer" >&2
                exit 1
            fi
            THRESHOLD_DAYS="$2"
            shift 2
            ;;
        --cert-dir)
            if [[ "$2" =~ \.\. ]]; then
                echo "Error: --cert-dir cannot contain directory traversal '..'" >&2
                exit 1
            fi
            case "$2" in
                /|/etc|/etc/*|/dev|/dev/*|/sys|/sys/*|/proc|/proc/*|/bin|/bin/*|/usr|/usr/*|/sbin|/sbin/*)
                    echo "Error: --cert-dir cannot target sensitive system directories" >&2
                    exit 1
                    ;;
            esac
            CERT_DIR="$2"
            shift 2
            ;;
        --san)
            validate_sans "$2"
            SANS="$2"
            shift 2
            ;;
        --p12-pass)
            P12_PASS="$2"
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

# Validate default SANs
validate_sans "$SANS"

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

# Set restrictive umask (0077) before file creation to prevent private key exposure race condition
OLD_UMASK=$(umask)
umask 0077

# Generate private key and self-signed certificate with Subject Alternative Names
if openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -days "$DAYS" \
    -subj "/CN=localhost" \
    -addext "subjectAltName=${SANS}" >/dev/null 2>&1; then
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
subjectAltName = ${SANS}
EOF
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days "$DAYS" \
        -config "$OPENSSL_CONF" >/dev/null 2>&1
    rm -f "$OPENSSL_CONF"
fi

# Export PKCS#12 bundle for macOS Keychain / iOS Simulator trust.
# NOTE: Defaults to empty password (pass:) for zero-friction local development/simulator import,
# or accepts --p12-pass for protected exports. Protected by filesystem mode 0600.
openssl pkcs12 -export \
    -out "$P12_FILE" \
    -inkey "$KEY_FILE" \
    -in "$CERT_FILE" \
    -name "Vapor Localhost Cert" \
    -passout "pass:$P12_PASS" >/dev/null 2>&1

# Restore previous umask and ensure public certificate is readable (0644)
umask "$OLD_UMASK"
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
