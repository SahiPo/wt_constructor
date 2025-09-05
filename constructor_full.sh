#!/usr/bin/env bash
# Walkthrough constructor — ALL-IN-ONE (wizard + spec → runnable walkthrough)
# This build:
# - Parses suggestions list blocks correctly (kind/note/content/cmd).
# - Safe with `set -u` (no "idx: unbound variable").
# - Snippet UX: :snippet edit doesn't truncate; :snippet open offers to insert snippet (append/overwrite) before opening.
# - Navigation: 'home' (h/?) redraws header+suggestions; tiny hint shown before every prompt.
# - Paging for suggestions: next_page/prev_page/page N/more; absolute numbering across pages.
# - No clipboard integration.

set -uo pipefail

pf(){ command printf "$@"; }
OUT="walkthrough.sh"
MODE=""
SPEC=""
DEBUG=0

usage() {
  cat <<'EOF'
Usage:
  constructor_all.sh --wizard [-o walkthrough.sh] [--debug]
  constructor_all.sh --from steps.walk [-o walkthrough.sh]

Spec (YAML-ish subset):
---
step: Creating config for OIDC
desc: |
  Multiline description...
suggestions:
  - kind: snippet
    note: |
      Optional hint shown above the snippet
    content: |
      # --- OIDC example snippet ---
      OIDCProviderMetadataURL https://issuer.example.com/.well-known/openid-configuration
      OIDCClientID           my-client-id
      OIDCClientSecret       my-super-secret
      OIDCRedirectURI        https://app.example.com/callback
      OIDCScope              "openid email profile"
      # --- end ---
  - kind: cmd
    note: Open the most likely config file
    cmd: |
      if [ -d /etc/httpd/conf.d ]; then
        ${EDITOR:-vi} /etc/httpd/conf.d/oidc.conf
      elif [ -d /etc/nginx/conf.d ]; then
        ${EDITOR:-vi} /etc/nginx/conf.d/oidc.conf
      else
        echo "Open your web server config manually (path varies)."
      fi
---
EOF
}

die(){ pf "Error: %s\n" "$*" >&2; exit 1; }
dbg(){ [ "${DEBUG:-0}" -eq 1 ] && pf "[debug] %s\n" "$*" >&2 || true; }

# ---- args
while [ $# -gt 0 ]; do
  case "$1" in
    --wizard) MODE="wizard"; shift;;
    --from) MODE="from"; SPEC="${2:-}"; [ -n "${SPEC:-}" ] || die "--from needs a file"; shift 2;;
    -o|--out) OUT="${2:-}"; [ -n "${OUT:-}" ] || die "-o needs a file"; shift 2;;
    --debug) DEBUG=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done
[ -n "${MODE:-}" ] || { usage; exit 1; }

# need TTY for wizard
if [ "${MODE}" = "wizard" ] && [ ! -t 0 ]; then
  die "Wizard needs an interactive TTY (run in a shell, not through a pipe)"
fi

TMPDIR="${TMPDIR:-/tmp}"
WORK_FLAT="$(mktemp "${TMPDIR}/walk_ctor_XXXX.flat")"
trap '[ "${DEBUG:-0}" -eq 1 ] || rm -f "$WORK_FLAT"' EXIT

# ---- prompt helpers
_prompt_out(){ if [ -t 0 ] && [ -w /dev/tty ]; then cat > /dev/tty; else cat >&2; fi; }
ask_line(){ local a=""; pf "%s" "$1" | _prompt_out; if [ -t 0 ] && [ -r /dev/tty ]; then IFS= read -r a < /dev/tty || a=""; else IFS= read -r a || a=""; fi; pf "%s" "$a"; }
ask_required_line(){ local a=""; while :; do a="$(ask_line "$1")"; [ -n "$a" ] && { pf "%s" "$a"; return; }; pf "\n(please enter a value)\n" | _prompt_out; done; }
ask_multiline(){
  pf "%s\n" "$1" | _prompt_out; pf "(finish with a single line: EOF)\n" | _prompt_out
  local buf="" line=""
  if [ -t 0 ] && [ -r /dev/tty ]; then
    while IFS= read -r line <&3; do [ "$line" = "EOF" ] && break; buf+="$line"$'\n'; done 3</dev/tty
  else
    while IFS= read -r line; do [ "$line" = "EOF" ] && break; buf+="$line"$'\n'; done
  fi
  pf "%s" "$buf"
}
confirm_yes(){ local a=""; while :; do a="$(ask_line "$1 [y/n]: ")"; case "${a,,}" in y|yes) return 0;; n|no|"") return 1;; *) pf "\nPlease answer y or n.\n" | _prompt_out;; esac; done; }
yn_yes(){ case "${1,,}" in y|yes|yeah|yup|да|д|s|si) return 0;; *) return 1;; esac; }
yn_done(){ case "${1,,}" in done|n|no|нет) return 0;; *) return 1;; esac; }

# ---- wizard -> .flat
run_wizard() {
  : > "$WORK_FLAT"
  pf "🧙 Interactive constructor\n" | _prompt_out
  pf "Add steps/suggestions; type 'done' to finish.\n\n" | _prompt_out

  local stepcount=0
  while :; do
    local ans; ans="$(ask_line "Add a new step? (y / done): ")"; pf "\n" | _prompt_out
    if yn_done "$ans"; then break; fi
    if ! yn_yes "$ans"; then continue; fi

    stepcount=$((stepcount+1))
    pf "Step %d\n-------\n" "$stepcount" | _prompt_out

    local title desc
    title="$(ask_required_line "  Title: ")"; pf "\n" | _prompt_out
    desc="$(ask_multiline "  Description (multiline; end with 'EOF'):")"; pf "\n" | _prompt_out

    pf "  Preview title: %s\n" "$title" | _prompt_out
    if [ -n "$desc" ]; then pf "  Preview desc:\n%s\n" "$desc" | _prompt_out; else pf "  (no description)\n" | _prompt_out; fi
    confirm_yes "  Save this step?" || { pf "  Discarded. Start over.\n\n" | _prompt_out; stepcount=$((stepcount-1)); continue; }

    printf 'STEP_Q|%q\n' "$title" >> "$WORK_FLAT"
    [ -n "$desc" ] && printf 'DESC_Q|%q\n' "$desc" >> "$WORK_FLAT"

    while :; do
      local kind note body
      local s_ans; s_ans="$(ask_line "  Add a suggestion? (y / done): ")"; pf "\n" | _prompt_out
      if yn_done "$s_ans"; then break; fi
      if ! yn_yes "$s_ans"; then continue; fi

      kind="$(ask_line "    Type (cmd/snippet) [cmd]: ")"; pf "\n" | _prompt_out
      kind="${kind:-cmd}"; case "${kind,,}" in cmd|snippet) : ;; *) kind="cmd" ;; esac
      note="$(ask_multiline "    Note (multiline; end with 'EOF'):")"; pf "\n" | _prompt_out
      if [ "$kind" = "cmd" ]; then body="$(ask_multiline "    Command (multiline; end with 'EOF'):")"; else body="$(ask_multiline "    Snippet content (multiline; end with 'EOF'):")"; fi
      pf "\n" | _prompt_out

      pf "    Preview kind: %s\n" "$kind" | _prompt_out
      [ -n "$note" ] && pf "    Note:\n%s\n" "$note" | _prompt_out
      pf "    %s:\n%s\n" "$([ "$kind" = cmd ] && echo Command || echo Content)" "$body" | _prompt_out

      confirm_yes "    Save this suggestion?" || { pf "    Discarded.\n\n" | _prompt_out; continue; }
      printf 'SUGG2_Q|%q|%q|%q|%q\n' "$kind" "" "$note" "$body" >> "$WORK_FLAT"
    done

    echo "ENDSTEP" >> "$WORK_FLAT"
    pf "\n" | _prompt_out
  done

  [ $stepcount -ge 1 ] || die "No steps added."
}

# ---- spec -> .flat (fixed list-mode parser)
parse_spec_flat() {
  [ -f "$SPEC" ] || die "Spec file not found: $SPEC"
  : > "$WORK_FLAT"

  awk -v OF="$WORK_FLAT" -v DBG="${DEBUG:-0}" '
  function dq(s,    t,i,c,qs){ qs=sprintf("%c",39); t="";
    for(i=1;i<=length(s);i++){ c=substr(s,i,1)
      if(c=="\\") t=t "\\\\";
      else if(c=="\n") t=t "\\n";
      else if(c=="\t") t=t "\\t";
      else if(c=="\r") t=t "\\r";
      else if(c==qs)  t=t "\\047";
      else            t=t c
    } return "$" qs t qs
  }
  function indent(s){ match(s,/^[ \t]*/); return RLENGTH }
  function strip_by(n,s){ return substr(s, n+1) }
  function read_block(base,   buf,ln,ind){ buf="";
    while ((getline ln)>0){
      sub(/\r$/,"",ln)
      if (ln ~ /^[ \t]*$/){ buf=buf "\n"; continue }
      ind=indent(ln)
      if (ind<=base){ backlog=ln; has_backlog=1; break }
      buf = buf strip_by(base+1, ln) "\n"
    } return buf
  }
  function flush_sugg(){
    if(!sugg_open) return
    kind = (sugg_kind=="" ? "cmd" : sugg_kind)
    body = (kind=="cmd" ? sugg_cmd : sugg_content)
    print "SUGG2_Q|" dq(kind) "|" dq("") "|" dq(sugg_note) "|" dq(body) >> OF
    if (DBG) printf("[debug] +sugg kind=%s note_len=%d body_len=%d\n", kind, length(sugg_note), length(body)) > "/dev/stderr"
    sugg_open=0; sugg_kind=""; sugg_note=""; sugg_cmd=""; sugg_content=""
  }
  function close_step(){
    if(!step_open) return
    flush_sugg()
    if(desc_acc!="") print "DESC_Q|" dq(desc_acc) >> OF
    print "ENDSTEP" >> OF
    if (DBG) printf("[debug] end step\n") > "/dev/stderr"
    step_open=0; desc_acc=""
  }

  BEGIN{
    step_open=0; desc_acc=""
    sugg_open=0; sugg_kind=""; sugg_note=""; sugg_cmd=""; sugg_content=""
    list_mode=0; list_base=0
    has_backlog=0
  }

  {
    while (1){
      if (has_backlog){ ln=backlog; has_backlog=0 } else { if ((getline ln)<=0) break }
      sub(/\r$/,"",ln)

      if (ln ~ /^[ \t]*---[ \t]*$/){ close_step(); continue }

      if (ln ~ /^[ \t]*step:[ \t]*/){
        close_step()
        st=ln; sub(/^[ \t]*step:[ \t]*/,"",st)
        print "STEP_Q|" dq(st) >> OF
        step_open=1; continue
      }

      if (ln ~ /^[ \t]*desc:[ \t]*\|[ \t]*$/){ base=indent(ln); desc_acc = read_block(base); continue }
      if (ln ~ /^[ \t]*desc:[ \t]*/){ s=ln; sub(/^[ \t]*desc:[ \t]*/,"",s); desc_acc = desc_acc s "\n"; continue }

      if (ln ~ /^[ \t]*suggestions:[ \t]*(#.*)?$/){ list_mode=1; list_base=indent(ln); continue }
      if (ln ~ /^[ \t]*suggestion:[ \t]*(#.*)?$/){ sugg_open=1; continue }

      if (list_mode){
        if (ln ~ /^[ \t]*-[ \t]*/){
          if (sugg_open) flush_sugg()
          sugg_open=1
          tmp=ln; sub(/^[ \t]*-[ \t]*/,"",tmp)
          if (tmp ~ /^[ \t]*kind:[ \t]*/){ sub(/^[ \t]*kind:[ \t]*/,"",tmp); gsub(/^[ \t]+/,"",tmp); sugg_kind=tmp; continue }
          if (tmp ~ /^[ \t]*note:[ \t]*\|[ \t]*$/){ base=indent(ln); sugg_note=read_block(base); continue }
          if (tmp ~ /^[ \t]*note:[ \t]*/){ sub(/^[ \t]*note:[ \t]*/,"",tmp); sugg_note = sugg_note tmp "\n"; continue }
          if (tmp ~ /^[ \t]*cmd:[ \t]*\|[ \t]*$/){ base=indent(ln); sugg_cmd=read_block(base); continue }
          if (tmp ~ /^[ \t]*cmd:[ \t]*/){ sub(/^[ \t]*cmd:[ \t]*/,"",tmp); sugg_cmd = sugg_cmd tmp "\n"; continue }
          if (tmp ~ /^[ \t]*content:[ \t]*\|[ \t]*$/){ base=indent(ln); sugg_content=read_block(base); continue }
          if (tmp ~ /^[ \t]*content:[ \t]*/){ sub(/^[ \t]*content:[ \t]*/,"",tmp); sugg_content = sugg_content tmp "\n"; continue }
          continue
        }
        if (indent(ln) <= list_base){ backlog=ln; has_backlog=1; list_mode=0; continue }

        if (ln ~ /^[ \t]*kind:[ \t]*/){ s=ln; sub(/^[ \t]*kind:[ \t]*/,"",s); gsub(/^[ \t]+/,"",s); sugg_kind=s; continue }
        if (ln ~ /^[ \t]*note:[ \t]*\|[ \t]*$/){ base=indent(ln); sugg_note=read_block(base); continue }
        if (ln ~ /^[ \t]*note:[ \t]*/){ s=ln; sub(/^[ \t]*note:[ \t]*/,"",s); sugg_note = sugg_note s "\n"; continue }
        if (ln ~ /^[ \t]*cmd:[ \t]*\|[ \t]*/){ base=indent(ln); sugg_cmd=read_block(base); continue }
        if (ln ~ /^[ \t]*cmd:[ \t]*/){ s=ln; sub(/^[ \t]*cmd:[ \t]*/,"",s); sugg_cmd = sugg_cmd s "\n"; continue }
        if (ln ~ /^[ \t]*content:[ \t]*\|[ \t]*/){ base=indent(ln); sugg_content=read_block(base); continue }
        if (ln ~ /^[ \t]*content:[ \t]*/){ s=ln; sub(/^[ \t]*content:[ \t]*/,"",s); sugg_content = sugg_content s "\n"; continue }
        continue
      }

      if (sugg_open){
        if (ln ~ /^[ \t]*kind:[ \t]*/){ s=ln; sub(/^[ \t]*kind:[ \t]*/,"",s); gsub(/^[ \t]+/,"",s); sugg_kind=s; continue }
        if (ln ~ /^[ \t]*note:[ \t]*\|[ \t]*/){ base=indent(ln); sugg_note=read_block(base); continue }
        if (ln ~ /^[ \t]*note:[ \t]*/){ s=ln; sub(/^[ \t]*note:[ \t]*/,"",s); sugg_note = sugg_note s "\n"; continue }
        if (ln ~ /^[ \t]*cmd:[ \t]*\|[ \t]*/){ base=indent(ln); sugg_cmd=read_block(base); continue }
        if (ln ~ /^[ \t]*cmd:[ \t]*/){ s=ln; sub(/^[ \t]*cmd:[ \t]*/,"",s); sugg_cmd = sugg_cmd s "\n"; continue }
        if (ln ~ /^[ \t]*content:[ \t]*\|[ \t]*/){ base=indent(ln); sugg_content=read_block(base); continue }
        if (ln ~ /^[ \t]*content:[ \t]*/){ s=ln; sub(/^[ \t]*content:[ \t]*/,"",s); sugg_content = sugg_content s "\n"; continue }
      }
    }
    close_step()
  }
  ' /dev/stdin < "$SPEC"

  if [ "${DEBUG:-0}" -eq 1 ]; then
    echo "[debug] flat:" >&2
    nl -ba "$WORK_FLAT" >&2 || true
  fi
}

# ---- emitter (writes array assignments atomically)
emit_walkthrough() {
  cat >"$OUT" <<'RUNTIME'
#!/usr/bin/env bash
set -uo pipefail
EDITOR="${EDITOR:-}"; VISUAL="${VISUAL:-}"
TMPDIR="${TMPDIR:-/tmp}"

__OLD_STTY=""; enable_tty_line_editing(){ if command -v stty >/dev/null 2>&1 && [ -t 0 ] && [ -t 1 ]; then __OLD_STTY="$(stty -g 2>/dev/null || true)"; stty sane 2>/dev/null || true; stty erase '^?' 2>/dev/null || stty erase '^H' 2>/dev/null || true; fi; }
restore_tty(){ [ -n "$__OLD_STTY" ] && stty "$__OLD_STTY" 2>/dev/null || true; }
choose_editor(){ local cand; for cand in "${VISUAL:-}" "${EDITOR:-}" nano vim nvim vi micro hx kak "emacs -nw"; do [ -n "$cand" ] || continue; set -- $cand; command -v "$1" >/dev/null 2>&1 && { printf "%s" "$cand"; return; }; done; printf "%s" "vi"; }
rule(){ echo; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
status_lines(){ local rc="${1:-0}" word; if [ "$rc" -eq 0 ]; then word="ok"; elif [ "$rc" -ge 128 ]; then word="interrupted"; else word="error"; fi; printf "exit code: %s\nresult: %s\n" "$rc" "$word"; }
run_cmd_tty(){ local cmd="$1"; echo; echo "── command ─────────────────────────────────────────"; echo "$cmd"; echo "───────────────────────────────────────────────────"; echo; bash -lc "$cmd"; local rc=$?; echo; status_lines "$rc"; echo "───────────────────────────────────────────────────"; }

# history
SCRIPT_NAME="$(basename "$0")"; STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}"; WALK_STATE_DIR="$STATE_BASE/walkthrough"; WALK_HISTFILE="$WALK_STATE_DIR/${SCRIPT_NAME}.hist"
mkdir -p "$WALK_STATE_DIR" 2>/dev/null || true
HISTFILE="$WALK_HISTFILE"; HISTSIZE="${HISTSIZE:-10000}"; HISTFILESIZE="${HISTFILESIZE:-20000}"
shopt -s histappend 2>/dev/null || true; builtin history -r "$HISTFILE" 2>/dev/null || true

# --- layout helpers
term_lines(){ local n; n="$(tput lines 2>/dev/null || echo 24)"; [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || n=24; printf "%s" "$n"; }
calc_pagesize(){ # reserve space for header + helpers; ensure at least 5
  local rows; rows="$(term_lines)"
  local ps=$(( rows - 18 ))
  [ "$ps" -lt 5 ] && ps=5
  printf "%s" "${WALK_SUGG_PAGESIZE:-$ps}"
}

# snippet stash
SNIP_STASH="$WALK_STATE_DIR/${SCRIPT_NAME}.snippet"
snippet_show(){ [ -s "$SNIP_STASH" ] && cat "$SNIP_STASH" || echo "(snippet stash is empty)"; }
snippet_edit(){ local ed; ed="$(choose_editor)"; touch "$SNIP_STASH"; "$ed" "$SNIP_STASH"; }   # no truncate
snippet_paste(){ local f="${1:-}" mode="${2:-}"; [ -n "$f" ] || { echo "usage: :snippet paste <file> [append|overwrite]"; return 1; }
  [ -s "$SNIP_STASH" ] || { echo "stash empty"; return 1; }
  case "${mode,,}" in overwrite|o) cat "$SNIP_STASH" > "$f" ;;
    append|a|"" ) cat "$SNIP_STASH" >> "$f" ;;
    * ) echo "mode must be append|overwrite"; return 1 ;;
  esac
  echo "✅ Snippet ${mode:-append}ed to $f"
}
snippet_open(){ # optionally insert, then open
  local f="${1:-}"; [ -n "$f" ] || { echo "file required"; return 1; }
  if [ -s "$SNIP_STASH" ]; then
    printf "Insert snippet into %s? [a]ppend / [o]verwrite / [s]kip: " "$f"; read -r ans || ans="s"
    case "${ans,,}" in
      a|append) snippet_paste "$f" append ;;
      o|overwrite) snippet_paste "$f" overwrite ;;
      * ) : ;;
    esac
  else
    echo "ℹ️ Snippet stash is empty; opening file."
  fi
  "$(choose_editor)" "$f"
}

# data
declare -a STEP_TITLES STEP_DESCS STEP_STATUS STEP_SIDX STEP_SLEN
declare -a SUGG_KIND SUGG_PATH SUGG_NOTE SUGG_BODY

CURRENT_STEP=1; TOTAL_STEPS=0
SUGG_PAGE=1

print_flow(){ echo; echo "Project Walkthrough Steps:"; local i marker; for ((i=1;i<=TOTAL_STEPS;i++)); do marker="•"; [[ ${STEP_STATUS[$i]:-todo} == "done" ]] && marker="✓"; [[ $i -eq $CURRENT_STEP ]] && marker="→"; echo " $marker [Step $i] ${STEP_TITLES[$i]:-}"; done; echo; }
print_step_header(){ clear; rule; echo " Welcome to Step $CURRENT_STEP — ${STEP_TITLES[$CURRENT_STEP]:-}"; rule; echo; if [[ -n "${STEP_DESCS[$CURRENT_STEP]:-}" ]]; then printf "%s\n\n" "${STEP_DESCS[$CURRENT_STEP]:-}"; fi; }
print_helpers_block(){
cat <<'EOF'
Helpers:
  • home / h / ?                      → Reprint header + suggestions (resets to page 1)
  • pick N / N                        → Edit & run/handle item N (absolute numbering)
  • show_suggestions (ss, show)       → Reprint just the list
  • next_page (np), prev_page (pp)    → Page through suggestions; 'more' = next_page
  • page N                            → Jump to page N
  • flow (f)                          → Show full flow
  • next_step (ns, next)              → Mark current step done & continue
  • goto_step N (goto N, g N)         → Jump to step N
  • finish                            → Check remaining steps & finish if OK
  • quit (q, :q, :quit)               → Exit walkthrough
  • exit (x)                          → Exit this shell only

  • snippet @ prompt:
      :snippet show
      :snippet edit                   # edit the stash (no truncation)
      :snippet open <file>            # optional insert, then open file
      :snippet paste <file> [append|overwrite]
EOF
}

print_suggestions(){
  echo "Suggested items for this step:"; echo "-------------------------------"
  local start=${STEP_SIDX[$CURRENT_STEP]:-0} len=${STEP_SLEN[$CURRENT_STEP]:-0}
  if (( len==0 )); then
    echo "  (none defined)"; echo
    print_helpers_block
    echo; return
  fi

  local pagesize maxpage
  pagesize="$(calc_pagesize)"
  (( pagesize<1 )) && pagesize=5
  maxpage=$(( (len + pagesize - 1) / pagesize ))
  (( SUGG_PAGE<1 )) && SUGG_PAGE=1
  (( SUGG_PAGE>maxpage )) && SUGG_PAGE=$maxpage

  local off=$(( (SUGG_PAGE-1) * pagesize ))
  local to=$(( off + pagesize )); (( to>len )) && to=$len

  local k idx n kind path note body
  for ((k=off; k<to; k++)); do
    idx=$((start+k)); n=$((k+1))  # absolute numbering across pages
    kind="${SUGG_KIND[$idx]:-cmd}"; path="${SUGG_PATH[$idx]:-}"; note="${SUGG_NOTE[$idx]:-}"; body="${SUGG_BODY[$idx]:-}"
    [ -n "$path" ] && echo ">>> [$n] ($kind → $path)" || echo ">>> [$n] ($kind)"
    [ -n "$note" ] && printf "%s" "$note" | sed 's/^/  # /'
    if [ -n "$body" ]; then printf "%s" "$body" | sed 's/^/  /'; else echo "  (open to view/edit)"; fi
    echo
  done
  echo "Page $SUGG_PAGE/$maxpage  —  use: next_page (np), prev_page (pp), page N, more"
  echo
  print_helpers_block
  echo
}

# Small always-visible hint before each prompt
hintbar(){ echo "[h] home  [?] help  [np/pp] page  [N] pick"; }

any_todo(){ local i; for ((i=1;i<=TOTAL_STEPS;i++)); do [[ "${STEP_STATUS[$i]:-todo}" != "done" ]] && return 0; done; return 1; }
finalize_and_exit(){ rule
  if any_todo; then echo "Some steps are still pending:"; print_flow; printf "Finish anyway? [y/N] "; read -r ans || ans=""
    case "${ans,,}" in y|yes) echo "🎉 Finishing despite pending steps."; echo "✅ Walkthrough completed!"; exit 0 ;;
      *) while :; do printf "Enter a step number to go to (1..$TOTAL_STEPS), or 'c' to cancel: "; read -r choice || choice=""
           case "${choice,,}" in c) echo "Okay, not finishing."; return 0 ;;
             *) if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=TOTAL_STEPS )); then CURRENT_STEP="$choice"; SUGG_PAGE=1; return 0; else echo "Pick 1..$TOTAL_STEPS or 'c'."; fi ;;
           esac
         done ;;
    esac
  else echo "🎉 All steps marked done."; echo "✅ Walkthrough completed!"; exit 0; fi
}

run_pick(){
  local n="$1" start=${STEP_SIDX[$CURRENT_STEP]:-0} len=${STEP_SLEN[$CURRENT_STEP]:-0}
  (( len>0 )) || { echo "❌ No items for this step."; return 1; }
  [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=len )) || { echo "❌ Invalid pick number."; return 1; }

  local idx=$((start + n - 1))
  local kind="${SUGG_KIND[$idx]:-cmd}" note="${SUGG_NOTE[$idx]:-}" body="${SUGG_BODY[$idx]:-}"

  case "$kind" in
    cmd)
      local tmpfile editor; tmpfile="$(mktemp "${TMPDIR}/walk_pick_XXXX.sh")"
      {
        echo "# Suggestion [$n] — ${STEP_TITLES[$CURRENT_STEP]:-}"
        if [[ -n "${STEP_DESCS[$CURRENT_STEP]:-}" ]]; then echo "# Step description:"; printf "%s" "${STEP_DESCS[$CURRENT_STEP]:-}" | sed 's/^/#   /'; [[ "${STEP_DESCS[$CURRENT_STEP]:-}" == *$'\n' ]] || echo "#"; echo "#"; fi
        if [[ -n "$note" ]]; then echo "# Suggestion note:"; printf "%s" "$note" | sed 's/^/#   /'; [[ "$note" == *$'\n' ]] || echo "#"; echo "#"; fi
        echo "# Lines starting with '#' are comments"; echo
        printf "%s" "$body"
      } > "$tmpfile"
      editor="$(choose_editor)"; echo; echo "🛠  Opening editor ($editor)..."; "$editor" "$tmpfile"
      echo; echo "── command ─────────────────────────────────────────"; grep -vE '^\s*#' "$tmpfile"; echo "───────────────────────────────────────────────────"; echo
      bash <(grep -vE '^\s*#' "$tmpfile"); local rc=$?; status_lines "$rc"; echo "───────────────────────────────────────────────────"; rm -f "$tmpfile"
      ;;
    snippet)
      local ed tmpf; ed="$(choose_editor)"; tmpf="$(mktemp "${TMPDIR}/walk_snip_XXXX.txt")"
      {
        echo "# ----------------------------------------------"
        echo "# ${STEP_TITLES[$CURRENT_STEP]:-} — snippet"
        echo "# ----------------------------------------------"
        if [ -n "$note" ]; then echo "# Note:"; printf "%s" "$note" | sed 's/^/#   /'; [[ "$note" == *$'\n' ]] || echo "#"; echo "#"; fi
        echo "# Edit the snippet between the markers. On save/exit it will be stashed."
        echo "# <<<SNIPPET>>>"; printf "%s" "$body"; [[ "$body" == *$'\n' ]] || echo; echo "# <<<END SNIPPET>>>"
      } > "$tmpf"
      echo; echo "🛠  Opening editor ($ed)..."; "$ed" "$tmpf"
      awk '/^# <<<SNIPPET>>>$/{g=1;next} /^# <<<END SNIPPET>>>/{g=0;exit} g{print}' "$tmpf" > "$SNIP_STASH"
      echo; echo "📌 Snippet stashed to: $SNIP_STASH"
      echo "Use: :snippet open <file>  (offers insert)  or  :snippet paste <file> [append|overwrite]"
      rm -f "$tmpf"
      ;;
    *) echo "Unknown item kind: $kind"; return 1 ;;
  esac
}

normalize_input(){
  local in="$1"
  case "${in,,}" in
    :q|:quit) echo "quit"; return ;;
    ss|show) echo "show_suggestions"; return ;;
    f) echo "flow"; return ;;
    ns|next) echo "next_step"; return ;;
    finish) echo "finish"; return ;;
    q) echo "quit"; return ;;
    x) echo "exit"; return ;;
    h|home|\?) echo "home"; return ;;
    more) echo "next_page"; return ;;
  esac
  [[ "$in" =~ ^:snippet[[:space:]]+(.+)$ ]] && { echo "snippet ${BASH_REMATCH[1]}"; return; }
  [[ "$in" =~ ^[0-9]+$ ]] && { echo "pick $in"; return; }
  [[ "$in" =~ ^(goto_step|goto|g)[[:space:]]+([0-9]+)$ ]] && { echo "goto_step ${BASH_REMATCH[2]}"; return; }
  [[ "$in" =~ ^page[[:space:]]+([0-9]+)$ ]] && { echo "page ${BASH_REMATCH[1]}"; return; }
  [[ "$in" =~ ^np$|^next_page$ ]] && { echo "next_page"; return; }
  [[ "$in" =~ ^pp$|^prev_page$ ]] && { echo "prev_page"; return; }
  echo "$in"
}

run_shell(){
  local input raw
  while :; do
    # Minimal pinned hint each time
    hintbar
    local __p="[STEP ${CURRENT_STEP}] > "
    if [ -t 0 ] && [ -t 1 ]; then builtin read -e -r -p "$__p" raw || { echo; break; }
    else printf "%s" "$__p"; IFS= read -r raw || { echo; break; }
    fi
    if [[ -n "${raw//[[:space:]]/}" ]]; then builtin history -s -- "$raw"; builtin history -w "$HISTFILE" 2>/dev/null || true; fi
    input="$(normalize_input "$raw")"
    if [[ "$input" =~ ^pick[[:space:]]+([0-9]+)$ ]]; then run_pick "${BASH_REMATCH[1]}"; continue; fi
    if [[ "$input" =~ ^goto_step[[:space:]]+([0-9]+)$ ]]; then local t="${BASH_REMATCH[1]}"; (( t>=1 && t<=TOTAL_STEPS )) && { CURRENT_STEP="$t"; SUGG_PAGE=1; return 0; } || { echo "❌ Step must be 1..$TOTAL_STEPS"; continue; }; fi
    case "$input" in
      "" ) : ;;
      home ) SUGG_PAGE=1; print_step_header; print_suggestions ;;
      show_suggestions ) print_suggestions ;;
      flow ) print_flow ;;
      next_step ) STEP_STATUS[$CURRENT_STEP]="done"; ((CURRENT_STEP++)); SUGG_PAGE=1; (( CURRENT_STEP>TOTAL_STEPS )) && { finalize_and_exit; } || return 0 ;;
      finish ) finalize_and_exit ;;
      next_page ) ((SUGG_PAGE++)); print_suggestions ;;
      prev_page ) ((SUGG_PAGE>1)) && ((SUGG_PAGE--)); print_suggestions ;;
      page\ * )
        set -- $input; shift
        local want="${1:-1}" len=${STEP_SLEN[$CURRENT_STEP]:-0} ps maxp
        ps="$(calc_pagesize)"; (( ps<1 )) && ps=5; maxp=$(( (len + ps - 1) / ps )); [[ "$want" =~ ^[0-9]+$ ]] && (( want>=1 && want<=maxp )) && SUGG_PAGE="$want"; print_suggestions ;;
      quit ) echo "👋 Exiting walkthrough..."; exit 0 ;;
      exit ) echo "↩️  Leaving shell for this step..."; return 0 ;;
      snippet\ * )
        set -- $input; shift
        sub="$1"; shift || true
        case "$sub" in
          show) snippet_show ;;
          edit|sedit) snippet_edit ;;
          open|sopen) snippet_open "${1:-}" ;;
          paste|insert) snippet_paste "${1:-}" "${2:-}" ;;
          *) echo "usage: :snippet show | edit | open <file> | paste <file> [append|overwrite]" ;;
        esac ;;
      * ) run_cmd_tty "$input" ;;
    esac
  done
}

main(){
  TOTAL_STEPS=${#STEP_TITLES[@]}-1; (( TOTAL_STEPS>=1 )) || { echo "No steps defined."; exit 1; }
  enable_tty_line_editing; trap restore_tty EXIT
  while (( CURRENT_STEP <= TOTAL_STEPS )); do
    SUGG_PAGE=1
    print_step_header; print_flow; printf "Press Enter to continue..."; IFS= read -r _ || true
    print_step_header; print_suggestions; run_shell
  done
  finalize_and_exit
}
RUNTIME

  {
    echo
    echo "# ---- Embedded data (generated) ----"
    echo "declare -a STEP_TITLES STEP_DESCS STEP_STATUS STEP_SIDX STEP_SLEN"
    echo "declare -a SUGG_KIND SUGG_PATH SUGG_NOTE SUGG_BODY"
    echo 'STEP_TITLES[0]=""; STEP_DESCS[0]=""'

    step=0
    sugg_index=0
    step_start=0

    while IFS= read -r line; do
      case "$line" in
        STEP_Q\|*)
          step=$((step+1))
          title_q="${line#STEP_Q|}"
          printf '%s\n' "STEP_TITLES[$step]=$title_q"
          step_start="$sugg_index"
          ;;
        DESC_Q\|*)
          desc_q="${line#DESC_Q|}"
          printf '%s\n' "STEP_DESCS[$step]=$desc_q"
          ;;
        SUGG2_Q\|*)
          rest="${line#SUGG2_Q|}"
          kind_q="${rest%%|*}"; rest="${rest#*|}"
          path_q="${rest%%|*}"; rest="${rest#*|}"
          note_q="${rest%%|*}"; body_q="${rest#*|}"
          printf '%s\n' "SUGG_KIND[$sugg_index]=$kind_q"
          printf '%s\n' "SUGG_PATH[$sugg_index]=$path_q"
          printf '%s\n' "SUGG_NOTE[$sugg_index]=$note_q"
          printf '%s\n' "SUGG_BODY[$sugg_index]=$body_q"
          sugg_index=$((sugg_index+1))
          ;;
        ENDSTEP)
          len=$((sugg_index - step_start))
          printf '%s\n' "STEP_SIDX[$step]=$step_start"
          printf '%s\n' "STEP_SLEN[$step]=$len"
          echo "STEP_STATUS[$step]=todo"
          ;;
      esac
    done < "$WORK_FLAT"

    echo
    echo 'main "$@"'
  } >> "$OUT"

  chmod +x "$OUT"
  pf "✅ Generated: %s\n" "$OUT"
}

# ---- build
if [ "${MODE}" = "wizard" ]; then
  run_wizard
elif [ "${MODE}" = "from" ]; then
  parse_spec_flat
else
  die "unknown mode"
fi
emit_walkthrough

