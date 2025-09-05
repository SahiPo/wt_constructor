# Interactive Walkthrough Constructor (Bash)

**Console-based interactive README constructor for Linux.**  
Build semi-interactive walkthroughs from a simple YAML template: define steps and per-step suggestions (commands or snippets) to generate a runnable Bash guide. Works in most Bash terminals.

---

## Features

- **Two ways to build**
  - `--from <spec.walk>`: generate from a YAML-ish spec file
  - `--wizard`: interactive authoring in your terminal
- **Single runnable script**: outputs a self-contained `walkthrough.sh`
- **Per-step suggestions**: each step can have many items (`cmd` or `snippet`)
- **Edit-before-run**: commands open in your editor to tweak before execution
- **Snippet stash**: capture/edit a snippet, then paste into files on demand
- **Paging**: large suggestion lists page cleanly (`np`, `pp`, `page N`, `more`)
- **History & state**: private command history + snippet stash saved under XDG state
- **Robust parser**: handles block scalars (`|`) and multi-line bodies
- **Safe runtime**: `set -u -o pipefail`, guarded array reads, TTY restore

---

## Requirements

- Linux, **Bash 4+**
- A terminal (TTY). Wizard mode requires an interactive TTY.
- An editor in `$VISUAL` or `$EDITOR` (falls back to `nano`, `vim`, `vi`, etc.)

---

## Install

```bash
git clone https://github.com/<you>/<repo>.git
cd <repo>
chmod +x constructor_all.sh   # main generator
```

*(If you use a different filename, adjust commands accordingly.)*

---

## Quick Start

Create a spec file `demo.walk`:

```yaml
---
step: Creating config for OIDC
desc: |
  Find (or create) the web server config file where OIDC settings belong.
  Paste the snippet and adjust issuer/client IDs and redirect URLs.
suggestions:
  - kind: snippet
    note: |
      Paste this block and modify placeholders.
    content: |
      # --- OIDC example snippet ---
      OIDCProviderMetadataURL https://issuer.example.com/.well-known/openid-configuration
      OIDCClientID           my-client-id
      OIDCClientSecret       my-super-secret
      OIDCRedirectURI        https://app.example.com/callback
      OIDCScope              "openid email profile"
      # --- end ---
  - kind: cmd
    note: |
      Open a likely config file (adjust for your distro).
    cmd: |
      if [ -d /etc/httpd/conf.d ]; then
        ${EDITOR:-vi} /etc/httpd/conf.d/oidc.conf
      elif [ -d /etc/nginx/conf.d ]; then
        ${EDITOR:-vi} /etc/nginx/conf.d/oidc.conf
      else
        echo "Open your web server config manually (path varies)."
      fi
```

**Generate and run:**

```bash
# Generate a runnable walkthrough script from the spec
./constructor_all.sh --from demo.walk -o walkthrough.sh

# Ensure the output is executable (constructor sets it, this is just explicit)
chmod +x walkthrough.sh

# Run it
./walkthrough.sh
```

You’ll see a header, the step description, and a (paged) list of suggestions.

---

## Using the Wizard

No spec yet? Let the wizard build one for you:

```bash
./constructor_all.sh --wizard -o walkthrough.sh

# Make sure it’s executable (constructor sets it, this is explicit)
chmod +x walkthrough.sh

./walkthrough.sh
```

The wizard prompts for step titles/descriptions and suggestions (cmd/snippet with notes and bodies).

---

## Runtime Controls

At the walkthrough prompt (`[STEP N] >`) you can use:

**Navigation**
- `home` (`h`, `?`) — redraw header + suggestions (resets to page 1)
- `flow` (`f`) — show all steps with progress
- `next_step` (`ns`, `next`) — mark current step done and continue
- `goto_step N` (`goto N`, `g N`) — jump to step N
- `finish` — attempt to finish (warns if steps pending)
- `quit` (`q`, `:q`, `:quit`) — exit the walkthrough
- `exit` (`x`) — leave the shell for the current step

**Suggestions**
- `pick N` or just `N` — open suggestion N  
  - `cmd` items: open in your editor, then run the edited script
  - `snippet` items: open a small editor buffer; saved text goes to the **snippet stash**

**Paging**
- `next_page` (`np`, `more`), `prev_page` (`pp`), `page N`

**Snippet operations**
- `:snippet show` — print the current stash
- `:snippet edit` — edit the stash file (no truncation)
- `:snippet open <file>` — optionally insert the stash (`append`/`overwrite`) then open file
- `:snippet paste <file> [append|overwrite]` — write stash to a file non-interactively

Small hint shown before each prompt:  
`[h] home  [?] help  [np/pp] page  [N] pick`

---

## YAML Spec Reference

A spec is a sequence of `---`-delimited documents, one per step.

```yaml
---
step: <Step title shown in UI>         # required, string
desc: |                                # optional, multi-line description
  ...
suggestions:                           # optional, list of suggestion items
  - kind: cmd                          # "cmd" or "snippet" (default "cmd")
    note: Short or multi-line note     # optional; shown above body
    cmd: |                             # required for kind=cmd
      multi-line shell
      commands go here
  - kind: snippet
    note: Why this snippet matters
    content: |                         # required for kind=snippet
      multi-line snippet content here
---
```

**Tips**
- Use block scalars `|` for multi-line fields (`desc`, `note`, `cmd`, `content`).
- You can have any number of suggestions per step.

---

## Environment Variables

- `EDITOR`, `VISUAL` — editor preference (e.g., `export EDITOR=nvim`)
- `TMPDIR` — where temp files are created (default `/tmp`)
- `XDG_STATE_HOME` — state dir for history/snippets (default `~/.local/state`)
- `WALK_SUGG_PAGESIZE` — **force paging** by limiting suggestions per page  
  Example: `WALK_SUGG_PAGESIZE=6 ./walkthrough.sh`

---

## Where State Is Stored

- History file: `~/.local/state/walkthrough/<script-name>.hist`
- Snippet stash: `~/.local/state/walkthrough/<script-name>.snippet`

(Respects `XDG_STATE_HOME` if set.)

---

## Sample Session

```
$ ./walkthrough.sh

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Welcome to Step 1 — Creating config for OIDC
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

 Find (or create) the web server config file where OIDC settings belong...
 
Suggested items for this step:
-------------------------------
>>> [1] (snippet)
  #  Paste this block and modify placeholders.
   # --- OIDC example snippet ---
   OIDCProviderMetadataURL ...
   ...

>>> [2] (cmd)
  #  Open a likely config file (adjust for your distro).
   if [ -d /etc/httpd/conf.d ]; then
     ${EDITOR:-vi} /etc/httpd/conf.d/oidc.conf
   ...

Page 1/1

[h] home  [?] help  [np/pp] page  [N] pick
[STEP 1] > 1      # pick snippet
... (edit and stash snippet)
[STEP 1] > :snippet paste /etc/nginx/conf.d/oidc.conf overwrite
✅ Snippet overwritten to /etc/nginx/conf.d/oidc.conf
```

---

## Troubleshooting

- **“Wizard needs an interactive TTY”**  
  Run the wizard directly in a terminal, not via a pipe.
- **Paging never appears**  
  Your terminal is tall. Force it: `WALK_SUGG_PAGESIZE=5 ./walkthrough.sh`.
- **Editor not found**  
  Set `$EDITOR` or `$VISUAL` (e.g., `export EDITOR=nano`). The script falls back to common editors.
- **Commands require root**  
  Some suggestions use `sudo`. Adjust or remove as needed for your environment.

---

## Contributing

- Issues and PRs welcome!
- Keep the generator POSIX-friendly where feasible; runtime is Bash-specific.
- When adding runtime commands, remember:
  - Don’t depend on GUI clipboard tools.
  - Keep `set -u -o pipefail` safety.
  - Prefer guarded array reads like `${ARR[$i]:-}`.

---

## License

MIT (see `LICENSE`).

---

## Credits

Built for teams who want **executable documentation**: living READMEs that guide and verify steps as you go.
