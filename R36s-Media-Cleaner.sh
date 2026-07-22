#!/usr/bin/env bash
#
# orphan_media_cleaner.sh
# ------------------------------------------------------------------
# Tool for R36S running dArkOS-RE (ArkOS/EmulationStation base) that
# finds media downloaded by ScreenScraper (images, videos, marquees,
# manuals, etc) that do NOT correspond to any game listed in the
# console's gamelist.xml, shows a per-console report, and asks for
# confirmation before deleting (or moving to a "trash" folder).
#
# Navigation: uses "dialog" (D-pad = arrows, A = Enter, B = Esc) with
# the gamepad converted to keyboard input via gptokeyb, the same way
# dArkOS/ArkOS itself does in tools like netplay.sh.
#
# Suggested installation:
#   1. Copy this file to /roms/tools/orphan_media_cleaner.sh
#      (or to your theme's "Applications/Ports" folder)
#   2. chmod +x orphan_media_cleaner.sh
#   3. Run it from the EmulationStation Applications/Ports menu,
#      or via SSH/terminal.
#
# Developed by: seerjo0
# ------------------------------------------------------------------

set -uo pipefail

{
    echo "[$(date '+%H:%M:%S' 2>/dev/null)] start: UI_SERVICE='${UI_SERVICE:-}' SSH_TTY='${SSH_TTY:-}' tty0_ok=$([ -c /dev/tty0 ] && echo yes || echo no)"
} >> /tmp/orphan_media_cleaner_launch.log 2>/dev/null || true

# ------------------------------------------------------------------
# RELAUNCH INSIDE A REAL TERMINAL (Weston/Sway/classic console)
# ArkOS/dArkOS builds that use Weston or Sway (Wayland) don't have a
# text console underneath: a "dialog" app launched directly by
# EmulationStation has nowhere to draw and dies instantly (the
# classic "screen flashes and goes back to the menu"). It needs to be
# opened INSIDE a Wayland terminal. This is the same scheme used by
# ThemeMaster, the dialog-based tool officially supported by dArkOS:
#   - Weston -> uses the "run" wrapper
#   - Sway   -> uses the "foot" terminal
#   - Neither of those (classic console/framebuffer) -> runs directly
# ------------------------------------------------------------------
if [ -z "${OMC_RELAUNCHED:-}" ]; then
    export OMC_RELAUNCHED=1
    case "${UI_SERVICE:-}" in
        weston.service)
            if command -v run >/dev/null 2>&1; then
                exec run "bash '$0'"
            fi
            ;;
        sway.service*|essway.service*)
            if command -v foot >/dev/null 2>&1; then
                exec foot -F bash "$0"
            fi
            ;;
    esac
fi

# ------------------------------------------------------------------
# TERMINAL FIX (fallback for classic/framebuffer consoles)
# If none of the cases above applied, still make sure stdin/stdout/
# stderr are on a real interactive terminal (the physical console),
# the same way other dArkOS dialog tools do (e.g. netplay.sh uses
# /dev/tty0). If run over SSH, this is skipped (the SSH terminal
# already works fine on its own).
# ------------------------------------------------------------------
export TERM="${TERM:-linux}"
if [ -z "${SSH_TTY:-}" ] && [ -c /dev/tty0 ] && [ -w /dev/tty0 ] && [ -r /dev/tty0 ]; then
    exec </dev/tty0 >/dev/tty0 2>/dev/tty0
fi

# ==================== CONFIGURATION ====================

# Folders where the script tries to auto-detect the roms root.
# Adjust/add to this list if your setup uses a different path.
ROMS_DIR_CANDIDATES=("/roms" "/roms2" "/home/ark/roms2/roms" "/storage/roms")

# Known media subfolders (ArkOS/ScreenScraper usually uses "images",
# but other variants/forks use different names; the script scans all
# of these that exist inside each console folder).
MEDIA_SUBDIRS=(images image videos video media marquees screenshots
               thumbnails box boxart manuals manual fanart wheel wheels
               cartridge covers)

# gamelist.xml tags that point to media files
MEDIA_TAGS="image|thumbnail|marquee|video|fanart|manual|boxart|screenshot|wheel|cartridge|cover"

# Paths where gptokeyb is usually found on ArkOS/dArkOS images
GPTOKEYB_CANDIDATES=("/opt/inttools/gptokeyb" "/opt/inttools/gptokeyb2"
                     "/usr/bin/gptokeyb2" "/usr/bin/gptokeyb"
                     "/usr/local/bin/gptokeyb2" "/usr/local/bin/gptokeyb")

# Delete mode: "trash" moves files to a backup folder (safer);
# "permanent" deletes them for good with rm -f.
DELETE_MODE="trash"

# ==================== INTERNAL STATE ====================

SCRIPT_NAME="$(basename "$0")"
TMP_DIR="$(mktemp -d /tmp/orphan_media.XXXXXX)"
LOG_FILE="/tmp/orphan_media_cleaner.log"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"
GPTOKEYB_PID=""
ROMS_DIR=""
declare -A ORPHAN_COUNT_BY_SYSTEM=()
declare -A ORPHAN_SIZE_BY_SYSTEM=()
ORPHAN_FULL_PATHS=()
ORPHAN_SYSTEM_OF_PATH=()
TOTAL_ORPHANS=0
TOTAL_SIZE=0

# Shows an error, logs it, and PAUSES the screen (without this, the
# screen just flashes and returns to EmulationStation with no time to
# read anything).
fail() {
    {
        echo "[$(date '+%H:%M:%S')] ERROR: $*"
    } | tee -a "$LOG_FILE" >&2
    echo
    echo "Log saved to: $LOG_FILE"
    echo "Press any button/key to go back..."
    read -n 1 -s -r || sleep 3
    exit 1
}
trap 'fail "unexpected error near line $LINENO (exit code $?)"' ERR

cleanup() {
    [ -n "$GPTOKEYB_PID" ] && kill "$GPTOKEYB_PID" >/dev/null 2>&1
    rm -rf "$TMP_DIR"
    clear
}
trap cleanup EXIT INT TERM

# ==================== GAMEPAD -> KEYBOARD ====================

start_gptokeyb() {
    local bin=""
    for cand in "${GPTOKEYB_CANDIDATES[@]}"; do
        if [ -x "$cand" ]; then
            bin="$cand"
            break
        fi
    done
    [ -z "$bin" ] && command -v gptokeyb2 >/dev/null 2>&1 && bin="$(command -v gptokeyb2)"
    [ -z "$bin" ] && command -v gptokeyb  >/dev/null 2>&1 && bin="$(command -v gptokeyb)"

    if [ -z "$bin" ]; then
        # No gptokeyb found: the script still works (keyboard/dialog only),
        # it just won't have D-pad/physical button navigation.
        return 0
    fi

    local gptk="$TMP_DIR/orphan_media.gptk"
    cat > "$gptk" <<'EOF'
up = up
down = down
left = left
right = right
dpup = up
dpdown = down
dpleft = left
dpright = right
a = enter
b = esc
start = enter
back = esc
l1 = pageup
r1 = pagedown
EOF

    "$bin" "$SCRIPT_NAME" -c "$gptk" >/dev/null 2>&1 &
    GPTOKEYB_PID=$!
    sleep 0.3
}

# ==================== HELPERS ====================

human_size() {
    local bytes="${1:-0}"
    if   [ "$bytes" -ge 1073741824 ]; then awk -v b="$bytes" 'BEGIN{printf "%.2f GB", b/1073741824}'
    elif [ "$bytes" -ge 1048576 ]; then awk -v b="$bytes" 'BEGIN{printf "%.2f MB", b/1048576}'
    elif [ "$bytes" -ge 1024 ]; then awk -v b="$bytes" 'BEGIN{printf "%.2f KB", b/1024}'
    else echo "${bytes} B"
    fi
}

find_roms_dir() {
    for d in "${ROMS_DIR_CANDIDATES[@]}"; do
        if [ -d "$d" ]; then
            ROMS_DIR="$d"
            return 0
        fi
    done
    return 1
}

# ==================== ANALYSIS ====================

# Extracts the set of referenced media paths from gamelist.xml
# (one per line, without the "./" prefix).
extract_referenced_media() {
    local gamelist="$1"
    grep -oE "<(${MEDIA_TAGS})>[^<]*</(${MEDIA_TAGS})>" "$gamelist" 2>/dev/null \
        | sed -E 's/^<[a-zA-Z]+>//; s/<\/[a-zA-Z]+>$//' \
        | sed -E 's#^\./##'
}

scan_orphans() {
    ORPHAN_COUNT_BY_SYSTEM=()
    ORPHAN_SIZE_BY_SYSTEM=()
    ORPHAN_FULL_PATHS=()
    ORPHAN_SYSTEM_OF_PATH=()
    TOTAL_ORPHANS=0
    TOTAL_SIZE=0

    local sys_dir system gamelist media_dir_name media_path
    local -A referenced

    for sys_dir in "$ROMS_DIR"/*/; do
        [ -d "$sys_dir" ] || continue
        system="$(basename "$sys_dir")"
        gamelist="${sys_dir}gamelist.xml"

        # No gamelist.xml means we can't safely tell what's valid -> skip this console
        [ -f "$gamelist" ] || continue

        referenced=()
        while IFS= read -r ref; do
            [ -n "$ref" ] && referenced["$ref"]=1
        done < <(extract_referenced_media "$gamelist")

        local sys_count=0
        local sys_size=0

        for media_dir_name in "${MEDIA_SUBDIRS[@]}"; do
            media_path="${sys_dir}${media_dir_name}"
            [ -d "$media_path" ] || continue

            while IFS= read -r -d '' file; do
                local rel="${file#"$sys_dir"}"
                rel="${rel#./}"
                if [ -z "${referenced[$rel]:-}" ]; then
                    local fsize
                    fsize=$(stat -c%s "$file" 2>/dev/null || echo 0)
                    ORPHAN_FULL_PATHS+=("$file")
                    ORPHAN_SYSTEM_OF_PATH+=("$system")
                    sys_count=$((sys_count + 1))
                    sys_size=$((sys_size + fsize))
                fi
            done < <(find "$media_path" -type f -print0 2>/dev/null)
        done

        if [ "$sys_count" -gt 0 ]; then
            ORPHAN_COUNT_BY_SYSTEM["$system"]=$sys_count
            ORPHAN_SIZE_BY_SYSTEM["$system"]=$sys_size
            TOTAL_ORPHANS=$((TOTAL_ORPHANS + sys_count))
            TOTAL_SIZE=$((TOTAL_SIZE + sys_size))
        fi
    done
}

build_summary_file() {
    local out="$1"
    {
        echo "ORPHAN MEDIA REPORT (no matching game in gamelist.xml)"
        echo "======================================================================"
        echo "Roms folder analyzed: $ROMS_DIR"
        echo
        if [ "$TOTAL_ORPHANS" -eq 0 ]; then
            echo "No orphan media found. Your collection is clean!"
        else
            printf "%-22s %10s %14s\n" "CONSOLE" "FILES" "SIZE"
            printf "%-22s %10s %14s\n" "----------------------" "----------" "--------------"
            for system in $(printf '%s\n' "${!ORPHAN_COUNT_BY_SYSTEM[@]}" | sort); do
                printf "%-22s %10s %14s\n" \
                    "$system" \
                    "${ORPHAN_COUNT_BY_SYSTEM[$system]}" \
                    "$(human_size "${ORPHAN_SIZE_BY_SYSTEM[$system]}")"
            done
            echo
            echo "----------------------------------------------------------------------"
            printf "TOTAL: %d orphan file(s), %s\n" "$TOTAL_ORPHANS" "$(human_size "$TOTAL_SIZE")"
        fi
    } > "$out"
}

build_detail_file() {
    local out="$1"
    {
        echo "DETAILED LIST OF ORPHAN FILES"
        echo "===================================="
        echo
        local i
        for i in "${!ORPHAN_FULL_PATHS[@]}"; do
            printf "[%s] %s\n" "${ORPHAN_SYSTEM_OF_PATH[$i]}" "${ORPHAN_FULL_PATHS[$i]#"$ROMS_DIR"/}"
        done
    } > "$out"
}

# ==================== ACTIONS ====================

do_delete_orphans() {
    local total="${#ORPHAN_FULL_PATHS[@]}"
    [ "$total" -eq 0 ] && return 0

    local backup_dir="$ROMS_DIR/.orphan_media_trash/$(date +%Y%m%d_%H%M%S)"
    local i moved=0 failed=0

    {
        for i in "${!ORPHAN_FULL_PATHS[@]}"; do
            local file="${ORPHAN_FULL_PATHS[$i]}"
            if [ "$DELETE_MODE" = "permanent" ]; then
                rm -f -- "$file" 2>/dev/null && moved=$((moved+1)) || failed=$((failed+1))
            else
                local rel="${file#"$ROMS_DIR"/}"
                local dest="$backup_dir/$rel"
                mkdir -p "$(dirname "$dest")" 2>/dev/null
                mv -- "$file" "$dest" 2>/dev/null && moved=$((moved+1)) || failed=$((failed+1))
            fi
            # percentage for the dialog gauge
            echo $(( (i + 1) * 100 / total ))
        done
    } | dialog --title "Removing orphan media..." --gauge "Processing files..." 8 60 0

    local msg
    if [ "$DELETE_MODE" = "permanent" ]; then
        msg="Done!\n\n$moved file(s) permanently deleted.\n$failed failure(s)."
    else
        msg="Done!\n\n$moved file(s) moved to trash:\n$backup_dir\n\n$failed failure(s).\n\nYou can delete that folder manually\nlater once you're sure."
    fi
    dialog --title "Result" --msgbox "$msg" 14 60
}

run_analysis_flow() {
    dialog --title "Analyzing..." --infobox "Looking for orphan media in:\n$ROMS_DIR\n\nThis may take a few seconds..." 8 50
    scan_orphans

    local summary_file="$TMP_DIR/summary.txt"
    build_summary_file "$summary_file"
    dialog --title "Analysis result" --textbox "$summary_file" 20 76

    if [ "$TOTAL_ORPHANS" -eq 0 ]; then
        return 0
    fi

    # Ask whether to view the detailed list
    if dialog --title "View details?" --yesno \
        "Would you like to see the full list of $TOTAL_ORPHANS orphan file(s) before deciding?" 8 60; then
        local detail_file="$TMP_DIR/detail.txt"
        build_detail_file "$detail_file"
        dialog --title "Orphan files" --textbox "$detail_file" 22 78
    fi

    local mode_label="moved to a trash folder (reversible)"
    [ "$DELETE_MODE" = "permanent" ] && mode_label="permanently deleted (NOT reversible)"

    if dialog --title "Confirm removal" --yesno \
        "Found $TOTAL_ORPHANS orphan file(s), totaling $(human_size "$TOTAL_SIZE").\n\nThese files will be $mode_label.\n\nDo you want to continue?" 12 64; then
        do_delete_orphans
    else
        dialog --title "Cancelled" --msgbox "No files were removed." 7 50
    fi
}

configure_menu() {
    while true; do
        local mode_desc="Move to trash (safe)"
        [ "$DELETE_MODE" = "permanent" ] && mode_desc="Delete permanently"

        local choice
        choice=$(dialog --title "Settings" --menu "Adjust options:" 15 62 4 \
            "1" "Roms folder: $ROMS_DIR" \
            "2" "Delete mode: $mode_desc" \
            "3" "Back" \
            3>&1 1>&2 2>&3)

        case "$choice" in
            1)
                local new_dir
                new_dir=$(dialog --title "Roms folder" --inputbox \
                    "Enter the full path to your roms folder\n(e.g. /roms):" 10 60 "$ROMS_DIR" \
                    3>&1 1>&2 2>&3)
                if [ -n "$new_dir" ] && [ -d "$new_dir" ]; then
                    ROMS_DIR="$new_dir"
                elif [ -n "$new_dir" ]; then
                    dialog --title "Error" --msgbox "Folder '$new_dir' does not exist." 7 50
                fi
                ;;
            2)
                if [ "$DELETE_MODE" = "trash" ]; then
                    if dialog --title "Confirm" --yesno \
                        "Switch to PERMANENT DELETE?\n\nFiles will not be recoverable." 9 55; then
                        DELETE_MODE="permanent"
                    fi
                else
                    DELETE_MODE="trash"
                fi
                ;;
            *)
                return 0
                ;;
        esac
    done
}

# ==================== MAIN MENU ====================

main_menu() {
    while true; do
        local choice
        choice=$(dialog --backtitle "Orphan Media Cleaner - dArkOS-RE | Developed by: seerjo0" \
            --title "Main menu" --menu "" 15 62 5 \
            "1" "Scan and clean orphan media" \
            "2" "Settings" \
            "3" "Exit" \
            3>&1 1>&2 2>&3)

        case "$choice" in
            1) run_analysis_flow ;;
            2) configure_menu ;;
            *) break ;;
        esac
    done
}

# ==================== START ====================

if ! command -v dialog >/dev/null 2>&1; then
    fail "'dialog' command not found. Install it with: opkg install dialog  (or)  apt-get install dialog"
fi

if ! find_roms_dir; then
    ROMS_DIR=$(dialog --title "Roms folder not found" --inputbox \
        "Could not auto-detect the roms folder.\nEnter the full path (e.g. /roms):" 10 60 "/roms" \
        3>&1 1>&2 2>&3)
    if [ -z "$ROMS_DIR" ] || [ ! -d "$ROMS_DIR" ]; then
        fail "invalid or empty roms folder ('$ROMS_DIR')."
    fi
fi

start_gptokeyb
main_menu
clear
exit 0
