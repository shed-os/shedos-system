shedos-review-exclude(5) "ShedOS" "File Formats"

# NAME

shedos-review-exclude - paths the .shedosnew conflict reviewer ignores

# SYNOPSIS

/etc/shedos/review-exclude.toml++
~/.config/shedos/review-exclude.toml

# DESCRIPTION

*shedman config --review* walks _$HOME_ looking for _\*.shedosnew_
files (the upstream copies that *shedos-sync-configs* drops when a
user-edited config diverges from a new package default). The
walker reads this file to decide which subtrees of _$HOME_ to skip.

Two files are consulted in order:

. /etc/shedos/review-exclude.toml -- system defaults, shipped by the
  *shedos-system* package.
. ~/.config/shedos/review-exclude.toml -- per-user overlay. Its
  *patterns* list _appends_ to the system list; its *skip_git_trees*
  setting (if present) _overrides_ the system value.

A missing file is fine; the loader falls through to the next. A
malformed file emits a single warning on stderr and the loader
falls back to a built-in default list, so a typo here never blinds
you to real conflicts.

This file is _distinct_ from _~/.config/shedos/sync-exclude_, which
uses glob syntax and tells *shedos-sync-configs* not to seed or drop
_.shedosnew_ files for those paths in the first place. The two
files cover different layers of the same pipeline.

# FORMAT

TOML, schema version 1.

```
output_schema_version = 1

patterns = [
    "^\\\\.cache/",
    "^Projects/",
]

skip_git_trees = true
```

*output_schema_version* (integer, required)
	Must be *1*. Reserved for future schema migrations.

*patterns* (array of strings, optional)
	Python _re_ regex patterns. Each pattern is matched against
	the relpath of a candidate _.shedosnew_ file under _$HOME_
	(no leading slash). Directories are matched against
	_relpath_ + _"/"_, so *^Projects/* matches the entire
	_Projects_ subtree.

*skip_git_trees* (boolean, optional, default *true*)
	Silently prune any directory containing a _.git_ entry
	(file or directory) -- typically a user project's working
	tree. _$HOME_ itself is never pruned this way, so users
	tracking their dotfiles in a HOME-level repo still get
	scanned.

# DEFAULTS

If neither file exists, or both fail to parse, the reviewer falls
back to this built-in list:

- _^\\.config/nvim/lazy-lock\\.json$_
- _^\\.config/nvim/lazyvim\\.json$_
- _^\\.local/state/_
- _^\\.cache/_
- _^Projects/_, _^src/_, _^code/_, _^dev/_, _^repos/_, _^work/_,
  _^go/_, _^rust/_

with *skip_git_trees = true*.

# EXAMPLES

Add a custom dev parent dir to your overlay:

```
# ~/.config/shedos/review-exclude.toml
output_schema_version = 1
patterns = ["^Workspace/", "^scratch/"]
```

Turn off the git-tree heuristic (the system list still applies):

```
output_schema_version = 1
skip_git_trees = false
```

# SEE ALSO

*shedman-config*(1), *shedman-update*(1).
