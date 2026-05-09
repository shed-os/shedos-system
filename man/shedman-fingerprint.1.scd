shedman-fingerprint(1) "ShedOS" "User Commands"

# NAME

shedman-fingerprint - manage user fingerprint enrollments via fprintd

# SYNOPSIS

*shedman fingerprint* _verb_ [_args_]

# DESCRIPTION

*shedman fingerprint* wraps the fprintd toolchain
(*fprintd-list*(1), *fprintd-enroll*(1), *fprintd-delete*(1),
*fprintd-verify*(1)) behind a single shedman verb so users learn
one CLI for fingerprint management instead of four. It also exposes
a per-finger delete via fprintd's D-Bus interface (the underlying
*fprintd-delete*(1) only does all-or-nothing) and a matcher
characterisation harness for FAR/FRR measurement.

# VERBS

*list*
	Show the current user's enrolled fingers and the device they
	are stored on.

*enroll* [_finger_]
	Walk through the 5-touch enrollment flow for _finger_ (default:
	*right-index-finger*). Rotate the finger across the sensor
	surface during the touches — broader template coverage gives
	the matcher more minutiae to anchor on at verify time.

*delete* _finger_
	Remove one enrolled finger. Requires holding a D-Bus claim
	across Claim+DeleteEnrolledFinger+Release; a small python-dbus
	helper does this on a single persistent connection.

*clear*
	Remove every enrolled finger for the current user.

*detect*
	Show the detected sensor model, device path, and the libfprint
	package providing the loaded driver.

*status*
	Combined view: sensor, driver, *fprintd*(1) service state, and
	currently enrolled fingers.

*test* [*-r* _N_] [*-w* _M_]
	Interactive matcher characterisation. Runs _N_ trials with the
	user's enrolled finger and _M_ trials with a non-enrolled
	finger, then computes the False Reject Rate (legitimate scans
	the matcher rejected) and False Accept Rate (non-enrolled
	scans the matcher accepted). Defaults: *-r 20 -w 20*. Requires
	an interactive terminal.

	A non-zero False Accept Rate is a hard signal that fingerprint
	unlock is unsafe at the loaded driver's match threshold —
	fingerprint should not be relied on for screen lock on that
	hardware until the driver is patched.

# FINGER NAMES

The accepted finger identifiers (matching fprintd's vocabulary):
*left-thumb*, *left-index-finger*, *left-middle-finger*,
*left-ring-finger*, *left-little-finger*, *right-thumb*,
*right-index-finger*, *right-middle-finger*, *right-ring-finger*,
*right-little-finger*.

# FILES

/usr/libexec/shedman/fingerprint
	The subcommand script.

# EXIT STATUS

*0*
	Verb completed successfully.

*1*
	Verb failed (validation error, fprintd error, claim conflict).

*2*
	*test* observed at least one False Accept — the matcher is
	unsafe at its current threshold.

# SEE ALSO

*shedman*(1), *shedman-screensaver*(1), *fprintd*(1),
*fprintd-enroll*(1), *fprintd-list*(1), *fprintd-verify*(1).
