# shellcheck shell=bash

asc_resolve_key() {
	local envfile="$HOME/.config/hasala/asc.env"
	if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]] && [[ -f "$envfile" ]]; then
		local envmode envowner
		envmode="$(/usr/bin/stat -f '%Lp' "$envfile")" || return 14
		envowner="$(/usr/bin/stat -f '%u' "$envfile")" || return 14
		if [[ "$envmode" != "600" && "$envmode" != "400" ]] || [[ "$envowner" != "$(id -u)" ]]; then
			echo "$envfile has mode $envmode (owner uid $envowner); it must be yours with mode 0600 (chmod 600)" >&2
			return 14
		fi
		# shellcheck disable=SC1090
		source "$envfile" || return 14
	fi
	if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
		echo "set ASC_KEY_ID and ASC_ISSUER_ID (or create ~/.config/hasala/asc.env)" >&2
		return 14
	fi
	if [[ ! "$ASC_KEY_ID" =~ ^[A-Za-z0-9]+$ ]]; then
		echo "ASC_KEY_ID must be the key's id (letters and digits only)" >&2
		return 14
	fi
	ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
	if [[ "${ASC_KEY_PATH##*/}" != "AuthKey_${ASC_KEY_ID}.p8" ]]; then
		echo "$ASC_KEY_PATH is not named AuthKey_${ASC_KEY_ID}.p8; the key file must be the one for ASC_KEY_ID, under that name" >&2
		return 14
	fi
	if [[ ! -f "$ASC_KEY_PATH" ]]; then
		echo "no API key file at $ASC_KEY_PATH" >&2
		return 14
	fi
	local mode
	mode="$(/usr/bin/stat -f '%Lp' "$ASC_KEY_PATH")" || return 14
	if [[ "$mode" != "600" && "$mode" != "400" ]]; then
		echo "$ASC_KEY_PATH has mode $mode; make it 0600 (chmod 600)" >&2
		return 14
	fi
	local repo keydir
	repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || return 14
	keydir="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd -P)" || return 14
	if [[ "$keydir/" == "$repo/"* ]]; then
		echo "$ASC_KEY_PATH is inside the repository; keep keys outside it" >&2
		return 14
	fi
	export ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH
}
