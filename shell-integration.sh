# Auto-launch a fixed list of GUI apps through swallow from an
# interactive shell, without a per-app wrapper script.
#
# Source this from ~/.bashrc, with SWALLOW_APPS set beforehand to whatever
# apps you want wrapped (`make install` adds an empty `SWALLOW_APPS=()`
# line above the source line for you to fill in):
#   SWALLOW_APPS=(kate gimp mpv feh zathura)
#   source /path/to/swallow/shell-integration.sh
#
# Bash functions are checked before $PATH, so defining one named e.g. "kate"
# shadows the real kate binary for interactive use only -- .desktop launchers
# and scripts that exec the binary directly are unaffected. Use `command
# kate` to bypass the wrapper and reach the real binary.

SWALLOW_FLAGS="--remain --occupy --timeout 3"

_swallow_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWALLOW_BIN="$_swallow_dir/swallow-auto.sh"
unset _swallow_dir

for _swallow_app in "${SWALLOW_APPS[@]}"; do
    eval "${_swallow_app}() { \"\$SWALLOW_BIN\" $SWALLOW_FLAGS \"$_swallow_app\" \"\$@\"; }"
done
unset _swallow_app
