shedman-kernel(1)

# NAME

shedman-kernel - list installed kernels and set the Limine default

# SYNOPSIS

*shedman kernel* {*-l*|*--list*}++
*sudo shedman kernel* *--set-default* _pkgbase_

# DESCRIPTION

Reads */usr/lib/modules/\*/pkgbase* to enumerate installed kernels
and manages which one Limine boots first.

# OPTIONS

*-l*, *--list*
	Show every installed kernel; *\** marks the configured
	default.

*--set-default* _pkgbase_
	Make _pkgbase_ the first Limine entry. Needs root; regenerates
	*/boot/limine.conf* (and its ESP mirrors) via
	*render-limine-config.sh*.

# SEE ALSO

*shedman*(1), *shedman-rollback*(1)
