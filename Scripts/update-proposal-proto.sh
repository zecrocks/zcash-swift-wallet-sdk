#!/usr/bin/env bash
#
# update-proposal-proto.sh: vendor the FFI proposal.proto from librustzcash.
#
# The canonical definition lives in zcash/librustzcash at
# zcash_client_backend/proto/proposal.proto. libzcashlc encodes proposals with
# whatever schema the pinned zcash_client_backend was built against, so the
# copy compiled into this SDK has to match that exact version: any field the
# copy lacks is a field Swift cannot read.
#
# Unlike the lightwallet protos there is no git subtree to derive from, because
# the upstream version is chosen by a Cargo dependency rather than by a tag this
# repository pulls. The pinned version is therefore read out of Cargo.lock and
# the matching upstream file is fetched over HTTPS.
#
# A crates.io release is normally tagged `<crate>-<version>` upstream, but not
# every release's tag is pushed. When the tag is missing the script falls back
# to the commit the crate was published from, which cargo records in the
# crate's `.cargo_vcs_info.json`. That file is read from the local cargo
# registry when the crate has been fetched, and otherwise from the published
# crate downloaded from crates.io and checked against the Cargo.lock checksum.
#
# The derivation adds one thing upstream does not carry: `option swift_prefix`.
# Without it the generated types would collide with the SDK's own names, so
# taking upstream verbatim is not an option.
#
# This script updates the .proto ONLY. The generated proposal.pb.swift is
# committed, so after running this you must regenerate it with protoc and the
# protoc-gen-swift version pinned in Package.resolved; see
# Scripts/update-lightwallet-protocol.sh, which builds that plugin and is the
# reference for how generated sources are produced in this repository.
#
# Usage:
#   ./Scripts/update-proposal-proto.sh           # rewrite the vendored copy
#   ./Scripts/update-proposal-proto.sh --check   # fail if it has drifted (CI)
#
# Both modes are idempotent and neither needs a clean working tree. --check
# writes nothing; it is what the Proto Sync workflow runs. A failed update
# leaves the vendored copy untouched.

set -euo pipefail

readonly UPSTREAM_REPO="zcash/librustzcash"
readonly UPSTREAM_PATH="zcash_client_backend/proto/proposal.proto"
readonly CRATE="zcash_client_backend"
readonly LOCK="Cargo.lock"
readonly DEST="Sources/ZcashLightClientKit/Modules/Service/GRPC/ProtoBuf/proto/proposal.proto"
readonly SWIFT_PREFIX="Ffi"
# crates.io rejects requests without a User-Agent that identifies the client.
readonly USER_AGENT="zcash-swift-wallet-sdk update-proposal-proto.sh (https://github.com/zecrocks/zcash-swift-wallet-sdk)"

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
cd "${REPO_ROOT}"

usage() {
    sed -n '2,40p' "$0" | sed 's|^# \{0,1\}||'
    exit "${1:-1}"
}

# Prints "<version><TAB><source><TAB><checksum>" for CRATE's entry in
# Cargo.lock. Cargo.lock separates [[package]] blocks with a blank line, which
# is what delimits a record here.
read_lock_entry() {
    awk -v want="${CRATE}" '
        /^\[\[package\]\]$/ { name = ""; version = ""; source = ""; checksum = ""; next }
        /^name = / { gsub(/^name = "|"$/, ""); name = $0; next }
        /^version = / { gsub(/^version = "|"$/, ""); version = $0; next }
        /^source = / { gsub(/^source = "|"$/, ""); source = $0; next }
        /^checksum = / { gsub(/^checksum = "|"$/, ""); checksum = $0; next }
        /^$/ { if (name == want) exit }
        # `exit` still runs END, which prints the one match either way.
        END { if (name == want) print version "\t" source "\t" checksum }
    ' "${LOCK}"
}

# Downloads the upstream proto at the given ref into the given file. Fails,
# leaving the file in an unspecified state, if the ref or file does not exist.
fetch_ref() {
    local ref="$1" out="$2"
    curl -fsSL "https://raw.githubusercontent.com/${UPSTREAM_REPO}/${ref}/${UPSTREAM_PATH}" -o "${out}"
}

# Prints the 40-hex-digit `git.sha1` of the .cargo_vcs_info.json on stdin.
vcs_info_sha() {
    sed -n 's/.*"sha1"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -n 1
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Prints the commit the given published version of CRATE was packaged from.
published_crate_sha() {
    local version="$1" checksum="$2"
    local info sha

    # Cargo verified the checksum of anything it unpacked into the registry.
    for info in "${CARGO_HOME:-${HOME}/.cargo}"/registry/src/*/"${CRATE}-${version}"/.cargo_vcs_info.json; do
        if [ -f "${info}" ]; then
            sha="$(vcs_info_sha < "${info}")"
            if [ -n "${sha}" ]; then
                echo "${sha}"
                return
            fi
        fi
    done

    local workdir crate
    workdir="$(mktemp -d)"
    # shellcheck disable=SC2064 # expand the path now, while it is still in scope
    trap "rm -rf '${workdir}'" RETURN
    crate="${workdir}/${CRATE}-${version}.crate"

    if ! curl -fsSL -A "${USER_AGENT}" \
        "https://crates.io/api/v1/crates/${CRATE}/${version}/download" -o "${crate}"; then
        echo "error: could not download ${CRATE} ${version} from crates.io." >&2
        return 1
    fi

    if [ -z "${checksum}" ] || [ "$(sha256_of "${crate}")" != "${checksum}" ]; then
        echo "error: the downloaded ${CRATE} ${version} does not match the ${LOCK} checksum." >&2
        return 1
    fi

    if ! tar -xzf "${crate}" -C "${workdir}" "${CRATE}-${version}/.cargo_vcs_info.json"; then
        echo "error: ${CRATE} ${version} carries no .cargo_vcs_info.json." >&2
        return 1
    fi

    sha="$(vcs_info_sha < "${workdir}/${CRATE}-${version}/.cargo_vcs_info.json")"
    if [ -z "${sha}" ]; then
        echo "error: ${CRATE} ${version}'s .cargo_vcs_info.json records no commit." >&2
        return 1
    fi
    echo "${sha}"
}

# Downloads the upstream proto for the pinned dependency into the given file
# and prints the ref it was taken from. A crates.io release is looked up by its
# `<crate>-<version>` tag, falling back to the commit it was published from; a
# git dependency pins an exact revision, which Cargo.lock records as the
# fragment of the source URL. Resolving the ref from the lockfile rather than
# from Cargo.toml keeps this correct while a librustzcash git override is in
# use.
fetch_upstream() {
    local out="$1"
    local entry version rest source checksum ref
    entry="$(read_lock_entry)"

    if [ -z "${entry}" ]; then
        echo "error: no ${CRATE} entry in ${LOCK}." >&2
        return 1
    fi

    version="${entry%%$'\t'*}"
    rest="${entry#*$'\t'}"
    source="${rest%%$'\t'*}"
    checksum="${rest#*$'\t'}"

    case "${source}" in
        registry+*)
            ref="${CRATE}-${version}"
            if ! fetch_ref "${ref}" "${out}"; then
                echo "note: could not fetch ${UPSTREAM_PATH} at tag ${ref} of ${UPSTREAM_REPO};" >&2
                echo "      using the commit ${CRATE} ${version} was published from." >&2
                ref="$(published_crate_sha "${version}" "${checksum}")" || return 1
                if ! fetch_ref "${ref}" "${out}"; then
                    echo "error: could not fetch ${UPSTREAM_PATH} at ${UPSTREAM_REPO}@${ref}." >&2
                    return 1
                fi
            fi
            ;;
        git+*)
            if [ "${source}" = "${source#*#}" ]; then
                echo "error: git source for ${CRATE} pins no revision: ${source}" >&2
                return 1
            fi
            ref="${source##*#}"
            if ! fetch_ref "${ref}" "${out}"; then
                echo "error: could not fetch ${UPSTREAM_PATH} at ${UPSTREAM_REPO}@${ref}." >&2
                echo "       Is ${ref} pushed to ${UPSTREAM_REPO}?" >&2
                return 1
            fi
            ;;
        *)
            echo "error: unrecognized source for ${CRATE}: '${source}'." >&2
            return 1
            ;;
    esac

    echo "${ref}"
}

# Writes the proto derived from the given upstream file to stdout.
derive() {
    local upstream="$1"

    if grep -q '^option swift_prefix' "${upstream}"; then
        echo "error: upstream now sets swift_prefix itself." >&2
        echo "       This script's injection is obsolete; vendor it verbatim." >&2
        return 1
    fi

    if ! grep -q '^package ' "${upstream}"; then
        echo "error: upstream has no 'package' declaration to anchor the injection." >&2
        return 1
    fi

    cat <<EOF
// DERIVED FILE -- DO NOT EDIT.
//
// Generated by Scripts/update-proposal-proto.sh from
// ${UPSTREAM_REPO}/${UPSTREAM_PATH}
// at the ${CRATE} version pinned in ${LOCK}.
//
// The only change from upstream is the added \`option swift_prefix\` below.
// Bump the dependency and re-run the script rather than editing this file,
// then regenerate proposal.pb.swift.

EOF
    awk -v prefix="${SWIFT_PREFIX}" '
        { print }
        !injected && /^package / {
            print "option swift_prefix = \"" prefix "\";"
            injected = 1
        }
    ' "${upstream}"
}

main() {
    local mode="${1:-update}"
    local workdir upstream derived ref
    workdir="$(mktemp -d)"
    # shellcheck disable=SC2064 # expand the path now, while it is in scope
    trap "rm -rf '${workdir}'" EXIT
    upstream="${workdir}/upstream.proto"
    derived="${workdir}/proposal.proto"

    # Derive into a scratch file first, so that no failure can truncate or
    # half-write the vendored copy.
    ref="$(fetch_upstream "${upstream}")"
    derive "${upstream}" > "${derived}"

    case "${mode}" in
        update)
            cp "${derived}" "${DEST}"
            echo "Derived ${DEST} from ${UPSTREAM_REPO}@${ref}."
            echo
            echo "proposal.pb.swift is committed and is NOT regenerated by this"
            echo "script. Regenerate it with the protoc-gen-swift version pinned"
            echo "in Package.resolved before committing; see"
            echo "Scripts/update-lightwallet-protocol.sh for how this repository"
            echo "builds that plugin."
            ;;
        check)
            if diff -u "${DEST}" "${derived}"; then
                echo "${DEST} matches ${UPSTREAM_REPO}@${ref}."
            else
                echo >&2
                echo "error: ${DEST} has drifted from ${UPSTREAM_REPO}@${ref}," >&2
                echo "       the ${CRATE} version pinned in ${LOCK}." >&2
                echo "       Run ./Scripts/update-proposal-proto.sh, regenerate" >&2
                echo "       proposal.pb.swift, and commit both." >&2
                exit 1
            fi
            ;;
    esac
}

case "${1:-}" in
    -h|--help)
        usage 0
        ;;
    --check)
        main check
        ;;
    '')
        main update
        ;;
    *)
        echo "error: unknown option '$1'." >&2
        usage 1
        ;;
esac
