shedman-lock(1)

# NAME

shedman-lock - lock the session

# SYNOPSIS

*shedman lock*

# DESCRIPTION

Emits a logind *LockSession*. hypridle's *lock_cmd* listens for it
and starts *shedos-screensaver-lock.service*, which runs the
fail-closed lock client (password + fingerprint unlock). Bound to
*Super+Escape* on the default desktop.

# SEE ALSO

*shedman*(1), *shedman-fingerprint*(1)
