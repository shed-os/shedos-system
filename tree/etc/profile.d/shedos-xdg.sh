# Export XDG Base Directory defaults system-wide so sudoers env_keep
# can preserve them across `sudo` for tools that respect XDG (nvim,
# shellcheck, git, …). Without this, users on non-zsh shells (or
# customised rcs that dropped the export) lose XDG state on sudo.
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_DATA_HOME:=$HOME/.local/share}"
: "${XDG_CACHE_HOME:=$HOME/.cache}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
