#!/usr/bin/env bash
#
# Scans each computer's LotDoneA.bat (read-only) to find which ones still point at the
# old backup share, so they can be flagged for update.
#
# Reads a CSV containing BrookSide PCs. For each hostname, reads
# \\<hostname>\c$\Brookside\LotDoneA.bat as text over SMB (via smbclient) and checks the
# "move" line used for Netcopy backups:
#
#   OLD (needs update): move c:\Brookside\Netcopy\*.* \\BSBak.camas.linear.com\Brookside\...
#   NEW (already done): move c:\Brookside\Netcopy\*.* \\camfs.ad.analog.com\DataBackup\Brookside\...
#
# Matching is done on the server/share prefix only, regardless of the destination folder
# name, so it doesn't need to match the computer's own hostname.
#
# Produces a CSV report listing every computer's status: NeedsUpdate, UpToDate,
# PatternNotFound, FileNotFound, FolderNotFound, Unreachable, or Error.
#
# Usage:
#   ./Check_LotADoneStorageLocation.bash [-i input.csv] [-o output.csv] [-n needs_update.csv] [-t throttle]
#
# Requirements:
#   - smbclient (brew install samba)
#   - Authentication: set SMB_AUTH_FILE to an smbclient auth file (username=/password=/domain=),
#     otherwise Kerberos (-k) is used.
#   - Optional: `timeout` (or `gtimeout` from coreutils) to cap how long each host can hang.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT_CSV="$SCRIPT_DIR/data/Camas Fab-systems-2026-09-24.csv"
OUTPUT_CSV="$SCRIPT_DIR/data/LotDoneA-StorageCheck-Results.csv"
NEEDS_UPDATE_CSV="$SCRIPT_DIR/data/Computers-NeedingUpdate.csv"
THROTTLE_LIMIT=10

while getopts "i:o:n:t:h" opt; do
    case "$opt" in
        i) INPUT_CSV="$OPTARG" ;;
        o) OUTPUT_CSV="$OPTARG" ;;
        n) NEEDS_UPDATE_CSV="$OPTARG" ;;
        t) THROTTLE_LIMIT="$OPTARG" ;;
        h|*)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 1
            ;;
    esac
done

OLD_PATTERNS=(
    'move c:\Brookside\Netcopy\*.* \\BSBak\Brookside\'
    'move c:\Brookside\Netcopy\*.* \\BSBak.camas.linear.com\Brookside\'
    'move c:\Brookside\Netcopy\*.* \\BSBak02\Brookside\'
)
NEW_PATTERNS=(
    'move c:\Brookside\Netcopy\*.* \\camfs\DataBackup\Brookside\'
    'move c:\Brookside\Netcopy\*.* \\camfs.ad.analog.com\DataBackup\Brookside\'
)

if ! command -v smbclient >/dev/null 2>&1; then
    echo "smbclient not found. Install it with: brew install samba" >&2
    exit 1
fi

if [[ ! -f "$INPUT_CSV" ]]; then
    echo "Input CSV not found: $INPUT_CSV" >&2
    exit 1
fi

if [[ -n "${SMB_AUTH_FILE:-}" ]]; then
    SMB_AUTH=(-A "$SMB_AUTH_FILE")
else
    SMB_AUTH=(-k)
fi

TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout 20"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout 20"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# --- Read hostnames from the CSV's 'Hostname' column ----------------------------------------

# Strip CRs and any UTF-8 BOM from the header line.
header="$(head -n 1 "$INPUT_CSV" | tr -d '\r\357\273\277')"
IFS=',' read -ra header_cols <<< "$header"

host_col=0
for i in "${!header_cols[@]}"; do
    name="$(echo "${header_cols[$i]}" | tr -d '"' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    if [[ "$name" == "hostname" ]]; then
        host_col=$((i + 1))
        break
    fi
done

if (( host_col == 0 )); then
    echo "Input CSV must contain a 'Hostname' column." >&2
    exit 1
fi

HOSTNAMES=()
while IFS= read -r line; do
    [[ -n "$line" ]] && HOSTNAMES+=("$line")
done < <(
    tail -n +2 "$INPUT_CSV" | tr -d '\r' |
        awk -F',' -v c="$host_col" '{ gsub(/"/, "", $c); gsub(/^[ \t]+|[ \t]+$/, "", $c); if ($c != "") print $c }'
)

# --- Helpers --------------------------------------------------------------------------------

# Runs one smbclient command against a host's C$ share. Fails on a non-zero exit or any NT_STATUS error.
smb() {
    local host="$1" cmd="$2" out rc
    out="$($TIMEOUT_CMD smbclient "//$host/c\$" "${SMB_AUTH[@]}" -c "$cmd" 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    (( rc == 0 )) && [[ "$out" != *NT_STATUS_* ]]
}

# Prints the first line of $1 containing any of the remaining patterns (case-insensitive, literal).
first_match() {
    local file="$1"; shift
    local args=() p
    for p in "$@"; do args+=(-e "$p"); done
    grep -i -F "${args[@]}" "$file" | head -n 1
}

join_lines() {
    awk 'NR > 1 { printf " | " } { printf "%s", $0 }'
}

csv_field() {
    local q='"'
    printf '"%s"' "${1//$q/$q$q}"
}

csv_row() {
    local out="" f
    for f in "$@"; do
        out+="$(csv_field "$f"),"
    done
    printf '%s\n' "${out%,}"
}

# --- Per-host check (runs in the background, one process per host) --------------------------

check_host() {
    local idx="$1" hostname="$2"
    local bat_path="\\\\$hostname\\c\$\\Brookside\\LotDoneA.bat"
    local bat_local="$WORK_DIR/$idx.bat"
    local status="Unknown" detail="" matched="" line

    local scanned_old scanned_new p
    scanned_old="$(printf "'%s' or " "${OLD_PATTERNS[@]}")"; scanned_old="${scanned_old% or }"
    scanned_new="$(printf "'%s' or " "${NEW_PATTERNS[@]}")"; scanned_new="${scanned_new% or }"

    if ! smb "$hostname" 'ls' >/dev/null; then
        status="Unreachable"
        detail="Could not connect to $hostname (no response from \\\\$hostname\\c\$ - offline, unreachable, or admin share not accessible)"
    elif ! smb "$hostname" "get \"Brookside\\LotDoneA.bat\" \"$bat_local\"" >/dev/null; then
        if smb "$hostname" 'cd Brookside' >/dev/null; then
            status="FileNotFound"
            detail="LotDoneA.bat not found at $bat_path"
        else
            status="FolderNotFound"
            detail="Connected to $hostname, but Brookside folder does not exist at \\\\$hostname\\c\$\\Brookside"
        fi
    else
        # Read-only: the file is only downloaded and grepped, never executed.
        # Strip CRs so CRLF batch files match cleanly.
        tr -d '\r' < "$bat_local" > "$bat_local.txt"

        local has_new has_old
        has_new="$(first_match "$bat_local.txt" "${NEW_PATTERNS[@]}")"
        has_old="$(first_match "$bat_local.txt" "${OLD_PATTERNS[@]}")"

        if [[ -n "$has_new" ]]; then
            status="UpToDate"
            detail="Points to new storage location"
            matched="$has_new"
        elif [[ -n "$has_old" ]]; then
            status="NeedsUpdate"
            detail="Still points to old storage location"
            matched="$has_old"
        else
            status="PatternNotFound"
            detail="Neither old nor new move line found"

            if [[ ! -s "$bat_local.txt" ]]; then
                matched="(file is empty)"
            else
                local move_lines
                move_lines="$(grep -i 'move' "$bat_local.txt" | join_lines)"
                if [[ -n "$move_lines" ]]; then
                    matched="No pattern match. Move line(s) found: $move_lines"
                else
                    matched="No pattern match, and no 'move' line in file. Full contents: $(join_lines < "$bat_local.txt")"
                fi
            fi
        fi
    fi

    printf '%s' "$status"  > "$WORK_DIR/$idx.status"
    printf '%s' "$detail"  > "$WORK_DIR/$idx.detail"
    printf '%s' "$bat_path" > "$WORK_DIR/$idx.batpath"
    printf '%s' "$matched" > "$WORK_DIR/$idx.matched"
    printf '%s' "$scanned_old" > "$WORK_DIR/$idx.scanned_old"
    printf '%s' "$scanned_new" > "$WORK_DIR/$idx.scanned_new"
    date '+%Y-%m-%d %H:%M:%S' | tr -d '\n' > "$WORK_DIR/$idx.checked"

    # One printf per host so output from concurrent checks doesn't interleave.
    local msg
    msg="$hostname: $status - $detail"$'\n'
    msg+="    Scanning for OLD: $scanned_old"$'\n'
    msg+="    Scanning for NEW: $scanned_new"$'\n'
    if [[ -n "$matched" ]]; then
        msg+="    Found: $matched"$'\n'
    else
        msg+="    No matching line found"$'\n'
    fi
    printf '%s' "$msg"
}

field() { cat "$WORK_DIR/$1.$2"; }

# --- Run checks with limited concurrency ----------------------------------------------------

echo "Checking ${#HOSTNAMES[@]} computer(s) with up to $THROTTLE_LIMIT at a time..."

for i in "${!HOSTNAMES[@]}"; do
    while (( $(jobs -rp | wc -l) >= THROTTLE_LIMIT )); do
        sleep 0.2
    done
    check_host "$i" "${HOSTNAMES[$i]}" &
done
wait

# --- Write reports --------------------------------------------------------------------------

mkdir -p "$(dirname "$OUTPUT_CSV")" "$(dirname "$NEEDS_UPDATE_CSV")"

CSV_HEADER="$(csv_row Hostname Status Detail BatPath ScannedOld ScannedNew MatchedLine CheckedOn)"
echo "$CSV_HEADER" > "$OUTPUT_CSV"
echo "$CSV_HEADER" > "$NEEDS_UPDATE_CSV"

needs_update_count=0
for i in "${!HOSTNAMES[@]}"; do
    row="$(csv_row "${HOSTNAMES[$i]}" "$(field "$i" status)" "$(field "$i" detail)" "$(field "$i" batpath)" \
        "$(field "$i" scanned_old)" "$(field "$i" scanned_new)" "$(field "$i" matched)" "$(field "$i" checked)")"
    echo "$row" >> "$OUTPUT_CSV"
    if [[ "$(field "$i" status)" == "NeedsUpdate" ]]; then
        echo "$row" >> "$NEEDS_UPDATE_CSV"
        needs_update_count=$((needs_update_count + 1))
    fi
done

echo "Full results written to $OUTPUT_CSV"
echo "$needs_update_count computer(s) still on old storage location -> $NEEDS_UPDATE_CSV"

# Grouped summary, ordered so the computers needing action are shown last (easiest to spot).
write_status_section() {
    local title="$1"; shift
    local statuses=" $* "
    local count=0 i

    for i in "${!HOSTNAMES[@]}"; do
        [[ "$statuses" == *" $(field "$i" status) "* ]] && count=$((count + 1))
    done

    echo ""
    echo "< --- $title ($count) --- >"
    echo ""
    if (( count == 0 )); then
        echo "    (none)"
        return
    fi

    for i in "${!HOSTNAMES[@]}"; do
        if [[ "$statuses" == *" $(field "$i" status) "* ]]; then
            echo "    ${HOSTNAMES[$i]}: $(field "$i" detail)"
            if [[ -n "$(field "$i" matched)" ]]; then
                echo "        Found: $(field "$i" matched)"
            fi
        fi
    done
}

write_status_section 'Up to Date Locations' UpToDate
write_status_section "Couldn't Connect" Unreachable FolderNotFound FileNotFound Error
write_status_section 'Neither Location Found' PatternNotFound
write_status_section 'Outdated Locations (Needs Update)' NeedsUpdate
echo ""
