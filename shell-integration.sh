# Auto-launches SWALLOW_APPS through swallow, from an interactive
# shell. Source from ~/.bashrc, with SWALLOW_APPS/SWALLOW_FLAGS set
# first (`make install` adds template lines above the source line):
#   SWALLOW_APPS=(kate gimp mpv feh zathura)
#   SWALLOW_FLAGS="--remain --occupy --timeout 3"
#   source /path/to/swallow/shell-integration.sh
#
# Bash checks functions before $PATH, so this shadows each app for
# interactive use only. Use `command kate` to reach the real binary.

for _swallow_app in "${SWALLOW_APPS[@]}"; do
    eval "${_swallow_app}() { swallow $SWALLOW_FLAGS \"$_swallow_app\" \"\$@\"; }"
done
unset _swallow_app
