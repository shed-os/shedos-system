shedman-login(1)

# NAME

shedman-login - show or hide the username field on the login screens

# SYNOPSIS

*shedman login* {*--show-username*|*--hide-username*|*--status*}

# DESCRIPTION

Toggles *[login].show_username* in */etc/shedos/system.toml*. The
greeter and the lock screen render a username dropdown when it is true
(the default) and fall back to a password-only box for the configured
user when it is false. The setting is declarative: */etc/shedos/system.toml*
is the source of truth and the screens read it on their next launch.

# OPTIONS

*--show-username*
	Show the username dropdown. The default on a fresh install.

*--hide-username*
	Hide the field; the password box authenticates the configured
	user.

*--status*
	Print the current effective value.

# FILES

/etc/shedos/system.toml
	The *[login]* section is read by the greeter and lock screen.

# SEE ALSO

*shedman*(1), *shedman-theme*(1)
