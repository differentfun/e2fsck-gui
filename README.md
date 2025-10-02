# e2fsck-gui

Minimal Zenity front-end for running `e2fsck` with real-time progress and safety prompts.

## Requirements

- Bash 4+
- `sudo` or `pkexec` (to re-launch the script as root)
- `e2fsck` (`e2fsprogs` package)
- `lsblk` and `stdbuf`
- Graphical session with X11/Wayland

> The script checks for Zenity at runtime and offers to install it automatically using your package manager.

## Installation

- Interactive wizard: `./installer.sh` (choose install or uninstall when prompted)
- System-wide: `sudo ./installer.sh --install` (installs into `/usr/local`, adds the desktop entry, and creates the `e2fsck-gui` launcher)
- Per-user: `./installer.sh --user --install` (installs into `~/.local`; add `~/.local/bin` to `PATH` if needed)
- Uninstall: run the script with `--uninstall` (add `--force` to skip confirmations)
- Skip menu integration: append `--no-desktop`

## Usage

1. From the repo: `chmod +x e2fsck-gui.sh && sudo ./e2fsck-gui.sh` (or `pkexec ./e2fsck-gui.sh`). Without root the GUI cannot start.
2. If installed with `installer.sh`, run `e2fsck-gui` from a terminal or search for *ExtX Filesystem Checker* in your desktop menu.
3. Pick the ext* partition to inspect from the list.
4. Select the desired flags (read-only, auto-repair, verbose, etc.) and add optional advanced values for alternate superblocks, external journals, or custom flags.
5. Review the confirmation dialog and continue. Progress and textual output are streamed live; the detailed log is shown at the end.

> **Warning**: running `e2fsck` on a mounted filesystem can cause damage. Unmount the partition before starting the check.

## Features

- Filters only ext2/3/4 partitions via `lsblk`
- Common e2fsck flags exposed as checkboxes (`-n`, `-y`, `-p`, `-f`, `-c`, `-v`)
- Advanced form for `-b`, `-l`, or arbitrary flag strings
- Real-time progress bar using `e2fsck -C 0` output and automatic log viewer
- Automatic cleanup of temporary files on exit/interruption

## Limitations

- Numeric progress depends on the `e2fsck` version and may not always be accurate
- The Zenity progress dialog has no cancel button (closing the window sends SIGTERM to e2fsck)
- Only the most common package managers are detected for Zenity auto-install; others require manual setup

## Troubleshooting

- **Zenity theme mismatch**: launch the script from your desktop session (not pure sudo) so that `GTK_THEME`, `DISPLAY`, and friends are preserved.
- **Missing `e2fsck`**: install your distribution's `e2fsprogs` package.
- **`Failed to open display`**: ensure a graphical session is active and that `DISPLAY`/`XAUTHORITY` are available (avoid running from a plain TTY or SSH without X forwarding).
