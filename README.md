# autoresearch

generic runpod bootstrap for mech-interp / ai research projects. one
curl-pipe-bash from a fresh pod (root ssh, blank /workspace volume) to
"tmux + claude code running as a non-root user inside a uv venv".

## what it does

`setup.sh` takes a fresh runpod from absolute zero to a fully working
research environment in one invocation. specifically:

1. installs apt packages (git, tmux, vim, locales, fonts-noto-color-emoji)
   so claude code's box-drawing chars and emoji render correctly
2. generates the en_US.UTF-8 locale and persists it in root's + the
   user's .bashrc / .profile (also exports for the running shell)
3. installs node.js 22 from nodesource
4. creates a non-root user (default `researcher`) with ssh keys mirrored
   from root, so `ssh user@pod` works on the next session
5. pre-creates `/workspace/.cache` and `/workspace/.cache/huggingface`
   with chmod 777 so the per-user setup doesn't eacces on hf cache mkdirs
6. clones your repo at the requested branch into
   `/workspace/<user>/<repo>`
7. runs your repo's `scripts/runpod_setup.sh` (uv sync + .env template)
   if it exists; otherwise prints what's missing
8. installs claude code globally for the user (npm prefix is set to
   `~/.npm-global` BEFORE the install so it doesn't try `/usr/lib`)
9. drops a sane `~/.tmux.conf` with `default-terminal=tmux-256color` +
   truecolor passthrough, so claude code renders correctly inside tmux
10. prints a clear step-by-step "what to do next" block at the end

idempotent. re-running on a half-set-up pod is safe; every step checks
state before acting.

## usage

ssh into a fresh runpod as root, then:

```bash
curl -fsSL https://raw.githubusercontent.com/aniket-desh/autoresearch/main/setup.sh \
  | REPO=https://github.com/<owner>/<repo>.git \
    BRANCH=<branch> \
    USER_NAME=<user> \
    bash
```

then follow the printed step-by-step block (switch to user, fill in
.env, open tmux, launch claude code).

## configuration

env vars (each takes effect when piped into bash as above):

| var | required | default | what it does |
|---|---|---|---|
| `REPO` | yes | — | git url to clone (e.g. `https://github.com/me/proj.git`) |
| `BRANCH` | yes | — | branch to check out |
| `USER_NAME` | no | `researcher` | non-root user to create + run claude code as |
| `TMUX_SESSION` | no | `${USER_NAME}` | tmux session name printed in instructions |
| `KICKOFF_PROMPT` | no | (none) | first prompt to paste into claude code; if set, printed at end |
| `REPO_DIR_NAME` | no | `basename(REPO)` | clone target dir under `/workspace/<user>/` |

example with a kickoff prompt:

```bash
curl -fsSL https://raw.githubusercontent.com/aniket-desh/autoresearch/main/setup.sh \
  | REPO=https://github.com/me/myproject.git \
    BRANCH=main \
    USER_NAME=me \
    KICKOFF_PROMPT="read docs/kickoff.md and follow its instructions" \
    bash
```

## what's in the repo

```
setup.sh                          one-shot bootstrap (entry point)
scripts/runpod_setup.sh           generic project setup (uv + .env template)
scripts/runpod_activate.sh        generic activate (loads .env, prints status)
```

## bundled helpers (auto-installed into the cloned project)

`setup.sh` looks for these two scripts inside the cloned project repo:

- `scripts/runpod_setup.sh` — installs uv, runs `uv sync` against your
  `pyproject.toml`, creates a `.env` template with the standard mech-interp
  api keys (anthropic, hf, wandb, github), gitignores `.env`. called as
  the non-root user in step 5.
- `scripts/runpod_activate.sh` — sources `.env`, activates the uv venv,
  puts the repo on `PYTHONPATH`, prints a one-line status (which keys
  are set, gpu list). you source this manually inside tmux before
  launching claude code.

**if the project repo doesn't ship them, autoresearch curls its own
versions from `scripts/runpod_*.sh` in this repo and drops them into
`<project>/scripts/`** (only if missing — never overwrites a project's
custom version). this means even a brand-new project with nothing but a
`pyproject.toml` works out of the box.

if your project has its own setup needs (extra apt packages, custom
env vars, model prefetching), just add a `scripts/runpod_setup.sh` to
your repo and `setup.sh` will use it instead of the autoresearch default.

## bugs this script handles

each fix in `setup.sh` corresponds to a real bug hit on a runpod pod:

- **`mkdir /workspace/.cache` eacces** — `/workspace` is sometimes owned
  by an account that doesn't include the new user. fix: pre-create as
  root with chmod 777 in step 3, before handing off to the user-side
  setup.
- **`LANG=''` in current root shell** — `update-locale` only affects
  future login shells, not the running one. fix: also export in the
  script + write to root's .bashrc + print an explicit warning at end.
- **`npm install -g` eacces `/usr/lib/node_modules`** — npm prefix
  defaults to `/usr/lib` for non-root. fix: set prefix to
  `~/.npm-global` FIRST, verify with `npm config get prefix`, install
  loudly so any remaining errors surface (previous version suppressed
  output via `/dev/null`, masking failures).
- **`claude` not found in tmux** — user accidentally runs `tmux` while
  still being root, lands in tmux as root which has no claude in PATH.
  fix: print a loud "STEP 1 — switch to non-root user FIRST" banner so
  the correct sequence (`su - user → tmux → ...`) is unambiguous.
- **PATH not inherited by non-interactive shells** — write the npm-global
  + locale exports to BOTH `.bashrc` and `.profile` so `su` and `ssh` as
  the user inherit the right env whether interactive or not.

## license

mit. use it for whatever.
