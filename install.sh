#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM=${0##*/}
readonly LAYOUT=ku
readonly LAYOUT_BRIEF=ku
readonly LAYOUT_DESCRIPTION='Kurdish (Kurmanji)'
readonly LAYOUT_LANGUAGE=kur
readonly BACKUP_SUFFIX=pre-kurmanji

readonly SYSTEM_XKB_DIR=/usr/share/X11/xkb
readonly OVERRIDE_XKB_DIR=/etc/xkb
readonly USER_XKB_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/xkb
readonly RULE_SETS=(evdev base)

SCOPE=system
ACTION=install
ACTIVATE=1
SET_DEFAULT=0

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    readonly C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m'
    readonly C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_OFF=$'\e[0m'
else
    readonly C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_OFF=''
fi

step() { printf '%s==>%s %s%s%s\n' "$C_BLUE$C_BOLD" "$C_OFF" "$C_BOLD" "$*" "$C_OFF"; }
info() { printf '    %s\n' "$*"; }
good() { printf '    %s%s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
abort() { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

SOURCE_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SOURCE_DIR
readonly SOURCE_FILE=$SOURCE_DIR/$LAYOUT

WORK_DIR=''
cleanup() {
    if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

PRIVILEGE=()
resolve_privilege() {
    if (( EUID == 0 )); then
        PRIVILEGE=()
    elif command -v sudo >/dev/null 2>&1; then
        PRIVILEGE=(sudo)
    elif command -v doas >/dev/null 2>&1; then
        PRIVILEGE=(doas)
    else
        abort 'root privileges are required for a system-wide install; use --user instead'
    fi
}

as_root() { ${PRIVILEGE[@]+"${PRIVILEGE[@]}"} "$@"; }

elevated() {
    if [[ $SCOPE == user ]]; then
        "$@"
    else
        as_root "$@"
    fi
}

place_file() {
    local mode=$1 source=$2 target=$3
    elevated install -D -m "$mode" -- "$source" "$target"
}

drop_file() {
    local target=$1
    if [[ -e $target ]]; then
        elevated rm -f -- "$target"
    fi
}

prune_dir() {
    local target=$1
    if [[ -d $target ]]; then
        elevated rmdir --ignore-fail-on-non-empty -- "$target" 2>/dev/null || true
    fi
}

emit_layout_element() {
    cat <<ELEMENT
    <layout>
      <configItem>
        <name>$LAYOUT</name>
        <shortDescription>$LAYOUT_BRIEF</shortDescription>
        <description>$LAYOUT_DESCRIPTION</description>
        <languageList>
          <iso639Id>$LAYOUT_LANGUAGE</iso639Id>
        </languageList>
      </configItem>
      <variantList/>
    </layout>
ELEMENT
}

emit_registry_document() {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE xkbConfigRegistry SYSTEM "xkb.dtd">' \
        '<xkbConfigRegistry version="1.1">' \
        '  <modelList/>' \
        '  <layoutList>'
    emit_layout_element
    printf '%s\n' '  </layoutList>' '  <optionList/>' '</xkbConfigRegistry>'
}

strip_layout_from_xml() {
    awk -v target="$LAYOUT" '
        !inside && /^[[:space:]]*<layout>[[:space:]]*$/ {
            inside = 1; block = $0 ORS; matched = 0; variants = 0; next
        }
        inside {
            block = block $0 ORS
            if ($0 ~ /<variantList>/) variants = 1
            if ($0 ~ /<\/variantList>/) variants = 0
            if (!variants && index($0, "<name>" target "</name>")) matched = 1
            if ($0 ~ /^[[:space:]]*<\/layout>[[:space:]]*$/) {
                inside = 0
                if (!matched) printf "%s", block
                block = ""
            }
            next
        }
        { print }
        END { if (inside) printf "%s", block }
    '
}

insert_layout_into_xml() {
    local element=$1
    awk -v element="$element" '
        !placed && /^[[:space:]]*<\/layoutList>[[:space:]]*$/ {
            while ((getline line < element) > 0) print line
            close(element)
            placed = 1
        }
        { print }
    '
}

rewrite_registry_xml() {
    local file=$1 mode=$2 element=$3
    [[ -f $file ]] || return 0
    file=$(readlink -f -- "$file")

    local candidate=$WORK_DIR/registry.xml
    if [[ $mode == add ]]; then
        strip_layout_from_xml <"$file" | insert_layout_into_xml "$element" >"$candidate"
    else
        strip_layout_from_xml <"$file" >"$candidate"
    fi

    if cmp -s "$file" "$candidate"; then
        info "$file is already correct"
        return 0
    fi
    place_file 0644 "$candidate" "$file"
    good "$file"
}

rewrite_registry_lst() {
    local file=$1 mode=$2
    [[ -f $file ]] || return 0
    file=$(readlink -f -- "$file")

    local candidate=$WORK_DIR/registry.lst
    awk -v layout="$LAYOUT" -v description="$LAYOUT_DESCRIPTION" \
        -v adding="$([[ $mode == add ]] && printf 1 || printf 0)" '
        function release(   i, last) {
            last = count
            while (last > 0 && buffer[last] ~ /^[[:space:]]*$/) last--
            for (i = 1; i <= last; i++) print buffer[i]
            if (adding) printf "  %-16s%s\n", layout, description
            for (i = last + 1; i <= count; i++) print buffer[i]
            count = 0
        }
        /^![[:space:]]*layout[[:space:]]*$/ { print; section = 1; count = 0; next }
        section && /^!/ { release(); section = 0; print; next }
        section { if ($1 != layout) buffer[++count] = $0; next }
        { print }
        END { if (section) release() }
    ' "$file" >"$candidate"

    if cmp -s "$file" "$candidate"; then
        info "$file is already correct"
        return 0
    fi
    place_file 0644 "$candidate" "$file"
    good "$file"
}

layout_is_ours() {
    grep -qF "name[Group1] = \"$LAYOUT_DESCRIPTION\"" -- "$1" 2>/dev/null
}

preserve_foreign_symbols() {
    local target=$1 backup=$1.$BACKUP_SUFFIX
    if [[ -f $target && ! -e $backup ]] && ! layout_is_ours "$target"; then
        elevated cp -p -- "$target" "$backup"
        warn "an unrelated '$LAYOUT' symbols file was found; saved as $backup"
    fi
}

restore_foreign_symbols() {
    local target=$1 backup=$1.$BACKUP_SUFFIX
    if [[ -f $backup ]]; then
        elevated mv -f -- "$backup" "$target"
        good "restored $target"
    else
        drop_file "$target"
    fi
}

install_layout() {
    [[ -f $SOURCE_FILE ]] || abort "layout definition not found: $SOURCE_FILE"

    local element=$WORK_DIR/layout.xml
    emit_layout_element >"$element"
    local registry=$WORK_DIR/document.xml
    emit_registry_document >"$registry"

    if [[ $SCOPE == user ]]; then
        step "Installing into $USER_XKB_DIR"
        place_file 0644 "$SOURCE_FILE" "$USER_XKB_DIR/symbols/$LAYOUT"
        good "$USER_XKB_DIR/symbols/$LAYOUT"
        local set
        for set in "${RULE_SETS[@]}"; do
            place_file 0644 "$registry" "$USER_XKB_DIR/rules/$set.xml"
            good "$USER_XKB_DIR/rules/$set.xml"
        done
        return 0
    fi

    step "Installing into $SYSTEM_XKB_DIR"
    preserve_foreign_symbols "$SYSTEM_XKB_DIR/symbols/$LAYOUT"
    place_file 0644 "$SOURCE_FILE" "$SYSTEM_XKB_DIR/symbols/$LAYOUT"
    good "$SYSTEM_XKB_DIR/symbols/$LAYOUT"

    step 'Registering the layout in the XKB rules'
    local set
    for set in "${RULE_SETS[@]}"; do
        rewrite_registry_xml "$SYSTEM_XKB_DIR/rules/$set.xml" add "$element"
        rewrite_registry_lst "$SYSTEM_XKB_DIR/rules/$set.lst" add
    done

    step "Installing an update-resistant copy into $OVERRIDE_XKB_DIR"
    place_file 0644 "$SOURCE_FILE" "$OVERRIDE_XKB_DIR/symbols/$LAYOUT"
    good "$OVERRIDE_XKB_DIR/symbols/$LAYOUT"
    for set in "${RULE_SETS[@]}"; do
        place_file 0644 "$registry" "$OVERRIDE_XKB_DIR/rules/$set.xml"
        good "$OVERRIDE_XKB_DIR/rules/$set.xml"
    done
}

remove_layout() {
    if [[ $SCOPE == user ]]; then
        step "Removing from $USER_XKB_DIR"
        drop_file "$USER_XKB_DIR/symbols/$LAYOUT"
        local set
        for set in "${RULE_SETS[@]}"; do
            discard_registry_document "$USER_XKB_DIR/rules/$set.xml"
        done
        prune_dir "$USER_XKB_DIR/symbols"
        prune_dir "$USER_XKB_DIR/rules"
        prune_dir "$USER_XKB_DIR"
        good 'removed'
        return 0
    fi

    step "Removing from $SYSTEM_XKB_DIR"
    restore_foreign_symbols "$SYSTEM_XKB_DIR/symbols/$LAYOUT"

    step 'Deregistering the layout from the XKB rules'
    local set
    for set in "${RULE_SETS[@]}"; do
        rewrite_registry_xml "$SYSTEM_XKB_DIR/rules/$set.xml" remove ''
        rewrite_registry_lst "$SYSTEM_XKB_DIR/rules/$set.lst" remove
    done

    step "Removing from $OVERRIDE_XKB_DIR"
    drop_file "$OVERRIDE_XKB_DIR/symbols/$LAYOUT"
    for set in "${RULE_SETS[@]}"; do
        discard_registry_document "$OVERRIDE_XKB_DIR/rules/$set.xml"
    done
    prune_dir "$OVERRIDE_XKB_DIR/symbols"
    prune_dir "$OVERRIDE_XKB_DIR/rules"
    prune_dir "$OVERRIDE_XKB_DIR"
    good 'removed'
}

discard_registry_document() {
    local file=$1
    [[ -f $file ]] || return 0
    local candidate=$WORK_DIR/discard.xml
    strip_layout_from_xml <"$file" >"$candidate"
    if grep -q '<layout>' "$candidate"; then
        place_file 0644 "$candidate" "$file"
    else
        drop_file "$file"
    fi
}

verify_layout() {
    step 'Verifying that the layout compiles'
    local -a extra=()
    if [[ $SCOPE == user ]]; then
        extra=(--include "$USER_XKB_DIR" --include-defaults)
    fi

    if command -v xkbcli >/dev/null 2>&1 &&
        xkbcli compile-keymap --help >/dev/null 2>&1; then
        if xkbcli compile-keymap ${extra[@]+"${extra[@]}"} --layout "$LAYOUT" \
            >/dev/null 2>"$WORK_DIR/compile.log"; then
            good 'libxkbcommon accepts the layout'
        else
            cat -- "$WORK_DIR/compile.log" >&2
            abort 'the layout failed to compile; nothing was activated'
        fi
    elif command -v xkbcomp >/dev/null 2>&1; then
        printf 'xkb_keymap {\n  xkb_keycodes { include "evdev+aliases(qwerty)" };\n  xkb_types { include "complete" };\n  xkb_compat { include "complete" };\n  xkb_symbols { include "pc+%s+inet(evdev)" };\n};\n' \
            "$LAYOUT" >"$WORK_DIR/probe.xkb"
        if xkbcomp -w 0 -I"$USER_XKB_DIR" -I"$SYSTEM_XKB_DIR" -xkb \
            "$WORK_DIR/probe.xkb" "$WORK_DIR/probe.out" >"$WORK_DIR/compile.log" 2>&1; then
            good 'xkbcomp accepts the layout'
        else
            cat -- "$WORK_DIR/compile.log" >&2
            abort 'the layout failed to compile; nothing was activated'
        fi
    else
        warn 'no XKB compiler found; skipping verification'
    fi
}

session_type() {
    if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
        printf 'wayland'
    elif [[ -n ${DISPLAY:-} ]]; then
        printf 'x11'
    else
        printf '%s' "${XDG_SESSION_TYPE:-none}"
    fi
}

gnome_sources() { gsettings get org.gnome.desktop.input-sources sources 2>/dev/null; }

enable_gnome() {
    command -v gsettings >/dev/null 2>&1 || return 1
    local current updated
    current=$(gnome_sources) || return 1
    [[ -n $current ]] || return 1

    if [[ $current == *"'$LAYOUT')"* ]]; then
        good 'already listed in the GNOME input sources'
        return 0
    fi
    if [[ $current == *'[]'* ]]; then
        updated="[('xkb', '$LAYOUT')]"
    else
        updated="${current%]}, ('xkb', '$LAYOUT')]"
    fi
    gsettings set org.gnome.desktop.input-sources sources "$updated" || return 1
    good 'added to the GNOME input sources'
}

disable_gnome() {
    command -v gsettings >/dev/null 2>&1 || return 1
    local current updated
    current=$(gnome_sources) || return 1
    [[ $current == *"'$LAYOUT')"* ]] || return 0

    updated=$(printf '%s' "$current" | grep -o "('[^']*', *'[^']*')" |
        grep -v -- "'$LAYOUT')" | paste -sd, - || true)
    if [[ -n $updated ]]; then
        updated="[$updated]"
    else
        updated='[]'
    fi
    gsettings set org.gnome.desktop.input-sources sources "$updated" || return 1
    good 'removed from the GNOME input sources'
}

plasma_tool() {
    command -v "${1}6" 2>/dev/null || command -v "${1}5" 2>/dev/null
}

enable_plasma() {
    local writer reader layouts variants
    writer=$(plasma_tool kwriteconfig) || return 1
    reader=$(plasma_tool kreadconfig) || return 1

    layouts=$("$reader" --file kxkbrc --group Layout --key LayoutList 2>/dev/null || true)
    case ",$layouts," in
        *",$LAYOUT,"*)
            good 'already listed in the Plasma layouts'
            return 0
            ;;
    esac
    variants=$("$reader" --file kxkbrc --group Layout --key VariantList 2>/dev/null || true)
    if [[ -n $layouts ]]; then
        layouts="$layouts,$LAYOUT"
        variants="$variants,"
    else
        layouts=$LAYOUT
        variants=''
    fi
    "$writer" --file kxkbrc --group Layout --key Use true
    "$writer" --file kxkbrc --group Layout --key LayoutList "$layouts"
    "$writer" --file kxkbrc --group Layout --key VariantList "$variants"
    good 'added to the Plasma layouts'
    info 'Plasma applies the new list after the next login'
}

disable_plasma() {
    local writer reader layouts rebuilt entry
    writer=$(plasma_tool kwriteconfig) || return 1
    reader=$(plasma_tool kreadconfig) || return 1

    layouts=$("$reader" --file kxkbrc --group Layout --key LayoutList 2>/dev/null || true)
    case ",$layouts," in
        *",$LAYOUT,"*) ;;
        *) return 0 ;;
    esac
    rebuilt=''
    while IFS= read -r entry; do
        [[ $entry == "$LAYOUT" ]] && continue
        rebuilt+=${rebuilt:+,}$entry
    done < <(printf '%s' "$layouts" | tr ',' '\n')
    "$writer" --file kxkbrc --group Layout --key LayoutList "$rebuilt"
    "$writer" --file kxkbrc --group Layout --key VariantList ''
    good 'removed from the Plasma layouts'
}

enable_x11() {
    command -v setxkbmap >/dev/null 2>&1 || return 1
    [[ -n ${DISPLAY:-} ]] || return 1

    local layouts variants query
    query=$(setxkbmap -query 2>/dev/null) || return 1
    layouts=$(printf '%s\n' "$query" | awk '$1 == "layout:" { print $2 }')
    variants=$(printf '%s\n' "$query" | awk '$1 == "variant:" { print $2 }')

    case ",$layouts," in
        *",$LAYOUT,"*)
            good 'already active in the X11 session'
            return 0
            ;;
    esac
    if [[ -n $layouts ]]; then
        layouts="$layouts,$LAYOUT"
        if [[ -n $variants ]]; then
            variants="$variants,"
        fi
    else
        layouts=$LAYOUT
    fi

    local -a command=(setxkbmap)
    if [[ $SCOPE == user ]]; then
        command+=(-I"$USER_XKB_DIR")
    fi
    command+=(-layout "$layouts")
    if [[ -n $variants ]]; then
        command+=(-variant "$variants")
    fi
    "${command[@]}" || return 1
    good 'activated in the running X11 session'
}

apply_system_default() {
    command -v localectl >/dev/null 2>&1 || {
        warn 'localectl is unavailable; skipping the system default'
        return 0
    }
    if [[ $SCOPE == user ]]; then
        warn 'the system default cannot be set from a per-user install'
        return 0
    fi

    local status layouts model variants options
    status=$(localectl status 2>/dev/null || true)
    layouts=$(printf '%s\n' "$status" | sed -n 's/^[[:space:]]*X11 Layout:[[:space:]]*//p')
    model=$(printf '%s\n' "$status" | sed -n 's/^[[:space:]]*X11 Model:[[:space:]]*//p')
    variants=$(printf '%s\n' "$status" | sed -n 's/^[[:space:]]*X11 Variant:[[:space:]]*//p')
    options=$(printf '%s\n' "$status" | sed -n 's/^[[:space:]]*X11 Options:[[:space:]]*//p')

    case ",$layouts," in
        *",$LAYOUT,"*)
            good 'already the system default'
            return 0
            ;;
    esac
    if [[ -n $layouts ]]; then
        layouts="$layouts,$LAYOUT"
        if [[ -n $variants ]]; then
            variants="$variants,"
        fi
    else
        layouts=$LAYOUT
    fi
    as_root localectl set-x11-keymap "$layouts" "$model" "$variants" "$options"
    good 'stored as the system default'
}

activate_layout() {
    step 'Activating the layout'
    case ${XDG_CURRENT_DESKTOP:-} in
        *KDE* | *Plasma* | *plasma*)
            if enable_plasma; then
                return 0
            fi
            ;;
        *GNOME* | *Unity* | *Cinnamon*)
            if enable_gnome; then
                return 0
            fi
            ;;
    esac
    if enable_gnome; then
        return 0
    fi
    if enable_plasma; then
        return 0
    fi
    if enable_x11; then
        return 0
    fi

    warn 'this desktop could not be configured automatically'
    case "$(session_type)" in
        wayland)
            info "add '$LAYOUT' to the keyboard layouts of your compositor"
            info "sway and i3 users: set xkb_layout $LAYOUT in the input configuration"
            ;;
        *)
            info "run: setxkbmap $LAYOUT"
            ;;
    esac
}

deactivate_layout() {
    step 'Deactivating the layout'
    disable_gnome || true
    disable_plasma || true
}

report() {
    step 'Summary'
    info "layout name  : $LAYOUT"
    info "description  : $LAYOUT_DESCRIPTION"
    info "scope        : $SCOPE"
    info "session      : $(session_type)${XDG_CURRENT_DESKTOP:+ / $XDG_CURRENT_DESKTOP}"
    if [[ $SCOPE == system ]]; then
        info 're-run this script after an xkeyboard-config upgrade'
    fi
}

usage() {
    cat <<HELP
$PROGRAM - install the $LAYOUT_DESCRIPTION keyboard layout

Usage:
  $PROGRAM [options]

Options:
  --user           install into $USER_XKB_DIR without root privileges
  --system         install system-wide (default)
  --uninstall      remove the layout again
  --set-default    also store the layout as the system-wide default
  --no-activate    install only, do not touch the running session
  -h, --help       show this text

Without options the layout is installed system-wide, verified with the XKB
compiler and added to the input sources of the running desktop session.
HELP
}

parse_arguments() {
    while (($# > 0)); do
        case $1 in
            --user) SCOPE=user ;;
            --system) SCOPE=system ;;
            --uninstall | --remove) ACTION=uninstall ;;
            --set-default) SET_DEFAULT=1 ;;
            --no-activate) ACTIVATE=0 ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) abort "unknown option: $1" ;;
        esac
        shift
    done
}

main() {
    parse_arguments "$@"

    [[ $SCOPE == user ]] || resolve_privilege
    WORK_DIR=$(mktemp -d) || abort 'unable to create a temporary directory'

    if [[ $ACTION == uninstall ]]; then
        deactivate_layout
        remove_layout
        step 'Done'
        info 'log out and back in to drop the layout from the running session'
        return 0
    fi

    install_layout
    verify_layout
    if ((SET_DEFAULT)); then
        step 'Setting the system default'
        apply_system_default
    fi
    if ((ACTIVATE)); then
        activate_layout
    fi
    report
}

main "$@"
