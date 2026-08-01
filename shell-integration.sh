# Auto-launch a fixed list of GUI apps through swallow from an
# interactive shell, without a per-app wrapper script.
#
# Source this from ~/.bashrc:
#   source /path/to/swallow/shell-integration.sh
#
# Bash functions are checked before $PATH, so defining one named e.g. "kate"
# shadows the real kate binary for interactive use only -- .desktop launchers
# and scripts that exec the binary directly are unaffected. Use `command
# kate` to bypass the wrapper and reach the real binary.

SWALLOW_APPS=(kate gimp mpv feh zathura)
SWALLOW_FLAGS="--remain --occupy --timeout 3"

for _swallow_app in "${SWALLOW_APPS[@]}"; do
    eval "${_swallow_app}() { swallow $SWALLOW_FLAGS \"$_swallow_app\" \"\$@\"; }"
done
unset _swallow_app 
