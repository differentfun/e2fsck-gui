#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_SCRIPT="$SCRIPT_DIR/e2fsck-gui.sh"

usage() {
    cat <<'USAGE'
Usage: ./installer.sh [OPTIONS] [--install|--uninstall]

Options:
  --install         Run installation without prompting for the action
  --uninstall       Run uninstallation without prompting for the action
  --prefix=DIR      Install under DIR (default: /usr/local)
  --user            Install in $HOME/.local (overrides --prefix)
  --no-desktop      Skip desktop entry creation/removal
  --force           Overwrite or remove existing files without prompting
  -h, --help        Show this help message
USAGE
}

PREFIX="/usr/local"
USER_INSTALL=false
MANAGE_DESKTOP=true
FORCE=false
ACTION=""

for arg in "$@"; do
    case "$arg" in
        --install)
            if [[ -n $ACTION ]]; then
                printf 'Only one of --install/--uninstall can be used at a time.\n' >&2
                exit 1
            fi
            ACTION="install"
            ;;
        --uninstall)
            if [[ -n $ACTION ]]; then
                printf 'Only one of --install/--uninstall can be used at a time.\n' >&2
                exit 1
            fi
            ACTION="uninstall"
            ;;
        --prefix=*)
            PREFIX=${arg#*=}
            ;;
        --user)
            USER_INSTALL=true
            PREFIX="$HOME/.local"
            ;;
        --no-desktop)
            MANAGE_DESKTOP=false
            ;;
        --force)
            FORCE=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
    printf 'Cannot find e2fsck-gui.sh next to installer.sh.\n' >&2
    exit 1
fi

resolve_paths() {
    BINDIR="$PREFIX/bin"
    LIBDIR="$PREFIX/lib/e2fsck-gui"
    DESKTOP_DIR="$PREFIX/share/applications"
    DESKTOP_FILE="$DESKTOP_DIR/extx-filesystem-checker.desktop"
    TARGET_SCRIPT="$LIBDIR/e2fsck-gui.sh"
    WRAPPER_PATH="$BINDIR/e2fsck-gui"
}

confirm() {
    local prompt=$1
    if [[ $FORCE == true ]]; then
        return 0
    fi
    read -r -p "$prompt [y/N] " reply
    reply=${reply,,}
    [[ $reply == y || $reply == yes ]]
}

require_privileges() {
    if [[ $USER_INSTALL == true ]]; then
        return 0
    fi
    if [[ $EUID -ne 0 ]]; then
        printf 'Root privileges are required for prefix %s (use sudo or --user).\n' "$PREFIX" >&2
        exit 1
    fi
}

run_update_desktop() {
    local base
    base=$(dirname "$DESKTOP_DIR")
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$base" || true
    fi
}

do_install() {
    require_privileges
    resolve_paths

    mkdir -p "$BINDIR" "$LIBDIR"

    if [[ -e "$TARGET_SCRIPT" ]]; then
        confirm "Overwrite existing $TARGET_SCRIPT?" || {
            printf 'Installation aborted.\n'
            exit 1
        }
    fi

    if [[ -e "$WRAPPER_PATH" ]]; then
        confirm "Overwrite existing $WRAPPER_PATH?" || {
            printf 'Installation aborted.\n'
            exit 1
        }
    fi

    install -m 755 "$SOURCE_SCRIPT" "$TARGET_SCRIPT"

    cat >"$WRAPPER_PATH" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_PATH="__TARGET_SCRIPT__"
ENV_EXPORT=(
    "DISPLAY=${DISPLAY:-}"
    "XAUTHORITY=${XAUTHORITY:-}"
    "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
    "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}"
    "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-}"
    "GTK_THEME=${GTK_THEME:-}"
)
if [[ ${EUID} -eq 0 ]]; then
    exec "${SCRIPT_PATH}" "$@"
fi
exec pkexec env "${ENV_EXPORT[@]}" "${SCRIPT_PATH}" "$@"
WRAPPER
    sed -i "s#__TARGET_SCRIPT__#$TARGET_SCRIPT#g" "$WRAPPER_PATH"
    chmod 755 "$WRAPPER_PATH"

    if [[ $MANAGE_DESKTOP == true ]]; then
        mkdir -p "$DESKTOP_DIR"
        local exec_path="$WRAPPER_PATH"
        exec_path=${exec_path// /\ }
        cat >"$DESKTOP_FILE" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.0
Name=ExtX Filesystem Checker
Comment=Check ext2/3/4 filesystems with e2fsck via a guided dialog
Exec=$exec_path
Icon=drive-harddisk
Terminal=false
Categories=System;Utility;
DESKTOP
        printf 'Installed desktop entry: %s\n' "$DESKTOP_FILE"
        run_update_desktop
    fi

    printf 'Installed script to %s\n' "$TARGET_SCRIPT"
    printf 'Launcher available as %s\n' "$WRAPPER_PATH"
    if [[ $MANAGE_DESKTOP == true ]]; then
        printf 'A menu entry named "ExtX Filesystem Checker" should appear after refreshing your desktop cache.\n'
    fi
}

do_uninstall() {
    require_privileges
    resolve_paths

    local removed_any=false

    if [[ -e "$WRAPPER_PATH" ]]; then
        confirm "Remove $WRAPPER_PATH?" && {
            rm -f "$WRAPPER_PATH"
            printf 'Removed %s\n' "$WRAPPER_PATH"
            removed_any=true
        }
    fi

    if [[ -e "$TARGET_SCRIPT" ]]; then
        confirm "Remove $TARGET_SCRIPT?" && {
            rm -f "$TARGET_SCRIPT"
            printf 'Removed %s\n' "$TARGET_SCRIPT"
            removed_any=true
        }
    fi

    if [[ -d "$LIBDIR" ]]; then
        rmdir "$LIBDIR" 2>/dev/null && printf 'Removed empty directory %s\n' "$LIBDIR"
    fi

    if [[ $MANAGE_DESKTOP == true && -f "$DESKTOP_FILE" ]]; then
        confirm "Remove $DESKTOP_FILE?" && {
            rm -f "$DESKTOP_FILE"
            printf 'Removed desktop entry %s\n' "$DESKTOP_FILE"
            run_update_desktop
            removed_any=true
        }
    fi

    if [[ $removed_any == false ]]; then
        printf 'Nothing to remove under prefix %s.\n' "$PREFIX"
    fi
}

if [[ -z $ACTION ]]; then
    printf 'Select action:\n  1) Install\n  2) Uninstall\n  q) Quit\n> '
    read -r choice
    case ${choice,,} in
        1)
            ACTION="install"
            ;;
        2)
            ACTION="uninstall"
            ;;
        q|quit|exit|'')
            printf 'No action selected.\n'
            exit 0
            ;;
        *)
            printf 'Unknown selection.\n'
            exit 1
            ;;
    esac
fi

case "$ACTION" in
    install)
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    *)
        printf 'Unknown action: %s\n' "$ACTION" >&2
        exit 1
        ;;
esac
