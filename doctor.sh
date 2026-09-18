#!/usr/bin/env bash
# opencode-doctor — health checks for your opencode setup.
#
# Checks your global (~/.config/opencode) and project (.opencode + AGENTS.md)
# layers, prints a readable or JSON report, and can safely repair the most
# common problems. Scriptable: exit code 0 = healthy, 1 = warnings, 2 = fails.
#
# Dependencies: bash, opencode, python3 (stdlib only) — no third-party deps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DOC_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || printf '0.1.0')"
TOOL_NAME="opencode-doctor"

# ---------------------------------------------------------------- defaults --
JSON_MODE=false
DRY_RUN=false
DO_FIX=false
OFFLINE=false
VERBOSE=false
SCOPE="both"                      # both | global | project
PROJECT_DIR=""
GLOBAL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
HAVE_OPENCODE=false

# colors
C_OK="\033[0;32m"; C_WARN="\033[0;33m"; C_ERR="\033[0;31m"
C_INFO="\033[0;36m"; C_BOLD="\033[1m"; C_DIM="\033[0;90m"; C_RESET="\033[0m"
B_OK="${C_BOLD}${C_OK}[ OK ]${C_RESET}"
B_WARN="${C_BOLD}${C_WARN}[WARN]${C_RESET}"
B_FAIL="${C_BOLD}${C_ERR}[FAIL]${C_RESET}"
B_SKIP="${C_BOLD}${C_DIM}[SKIP]${C_RESET}"

results=()        # id|severity|status|name|detail|remedy
fixes_applied=()  # id|name|action
TMP_DIR=""
EFFECTIVE=""
FIX_CHANGED=false

# --------------------------------------------------------------- log utils --
info()  { if [ "$JSON_MODE" = false ]; then printf "%b\n" "${C_INFO}${1}${C_RESET}"; fi; }
ok()    { if [ "$JSON_MODE" = false ]; then printf "%b %s\n" "$B_OK" "$1"; fi; }
warn()  { if [ "$JSON_MODE" = false ]; then printf "%b %s\n" "$B_WARN" "$1"; fi; }
skip()  { if [ "$JSON_MODE" = false ]; then printf "%b %s\n" "$B_SKIP" "$1"; fi; }
err()   { printf "%b %s\n" "$B_FAIL" "$1" >&2; }
die()   { err "$1"; exit 2; }

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "required command not found: $1"
  fi
}

confirm() { # $1 question ; returns 0 if yes
  [ "${CI:-}" = "true" ] && return 0
  printf "%b" "${C_WARN}${1} [y/N] ${C_RESET}" >&2
  local a
  read -r a
  case "${a:-n}" in
    y|Y|yes|Yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# run(): respect --dry-run (print-only) vs real execution for side effects
run() {
  if [ "$DRY_RUN" = true ]; then
    printf "%b (dry-run) %s\n" "${C_DIM}would run${C_RESET}" "$*"
    return 0
  fi
  "$@"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\x1b\[[0-9;]*m//g'
}

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# ------------------------------------------------------------- usage/banner --
banner() {
  [ "$JSON_MODE" = true ] && return 0
  printf "%b\n" \
    "${C_DIM}┌─────────────────────────────────────────────┐${C_RESET}" \
    "${C_BOLD}${C_INFO}  ⌘ opencode-doctor  ${C_RESET}${C_DIM}v${DOC_VERSION}${C_RESET}" \
    "${C_DIM}  health checks for your opencode setup${C_RESET}" \
    "${C_DIM}└─────────────────────────────────────────────┘${C_RESET}"
}

usage() {
  cat <<'USAGE'
Usage: doctor.sh [options] [scope]

Scopes
  --global             check the global layer only (~/.config/opencode)
  --project <dir>      check the project layer (.opencode/ + AGENTS.md). Default: cwd
  --both               check global + project (default)

Options
  --json               machine-readable JSON report on stdout (no banner/colors)
  --fix                apply safe auto-repairs (with .doctor.bak.<ts> backups)
  --dry-run            preview what --fix would change, write nothing
  --offline            skip network checks (e.g. latest-version)
  --verbose            also print details for healthy checks
  -V, --version        print version and exit
  -h, --help           print this help and exit

Exit codes
  0  healthy            (no warnings, no failures)
  1  warnings found
  2  failures found     (or a fatal error)

Examples
  bash doctor.sh
  bash doctor.sh --global --json
  bash doctor.sh --fix --dry-run
  bash doctor.sh --project ./my-app --verbose
USAGE
}

version() { printf '%s %s\n' "$TOOL_NAME" "$DOC_VERSION"; }

# ------------------------------------------------------------ json helpers --
jsraw() { # decode JSON value string into a raw shell string
  python3 -c 'import json,sys
try:
    v=json.loads(sys.argv[1]); print(v if isinstance(v,str) else json.dumps(v))
except Exception: sys.exit(1)' "$1" 2>/dev/null || printf ''
}

jsfield() { # eval EXPR on a JSON string $1 -> JSON result
  python3 -c 'import json,sys
try:
    j=json.loads(sys.argv[1]); print(json.dumps(eval(sys.argv[2])))
except Exception: sys.exit(1)' "$1" "$2" 2>/dev/null || printf ''
}

eff_get() { # eval EXPR on effective config dict `d` -> JSON result
  python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2])))
except Exception: sys.exit(1)' "$EFFECTIVE" "$1" 2>/dev/null || printf ''
}

eff_dict() { # print "key<TAB>value" lines; value raw-decoded, dicts/list as JSON
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
v=eval(sys.argv[2])
def dump(k,val):
    if isinstance(val,(dict,list)): val=json.dumps(val)
    elif val is None: val=""
    else: val=str(val)
    print(str(k)+"\t"+val)
if isinstance(v,dict):
    for k,val in v.items(): dump(k,val)
elif isinstance(v,list):
    for it in v: dump("",it)
' "$EFFECTIVE" "$1" 2>/dev/null || true
}

strip_jsonc() { # comment-aware JSONC -> JSON (handles https:// inside strings)
  python3 -c 'import sys
src=open(sys.argv[1]).read()
out=[];i=0;n=len(src);in_str=False
while i<n:
    c=src[i]
    if in_str:
        out.append(c)
        if c=="\\" and i+1<n: out.append(src[i+1]); i+=2; continue
        if c=="\"": in_str=False
        i+=1; continue
    if c=="\"": in_str=True; out.append(c); i+=1; continue
    if c=="/" and i+1<n and src[i+1]=="/":
        j=src.find("\n",i); out.append("\n"); i=(n if j<0 else j+1); continue
    if c=="/" and i+1<n and src[i+1]=="*":
        j=src.find("*/",i+2); i=(n if j<0 else j+3); continue
    out.append(c); i+=1
print("".join(out))' "$1"
}

resolve_global_file() {
  [ -f "$GLOBAL_DIR/opencode.jsonc" ] && { printf '%s' "$GLOBAL_DIR/opencode.jsonc"; return; }
  [ -f "$GLOBAL_DIR/opencode.json" ]  && { printf '%s' "$GLOBAL_DIR/opencode.json";  return; }
  printf ''
}

# ---------------------------------------------------------- ambient env bits --
is_vm() {
  [ -f /.dockerenv ] && return 0
  [ -f /.flatpak-info ] && return 0
  [ -n "${DOCTOR_ASSUME_VM:-}" ] && return 0
  [ -f /proc/1/cgroup ] && grep -qE "docker|containerd|kubepods|lxc" /proc/1/cgroup 2>/dev/null && return 0
  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q -c 2>/dev/null; then return 0; fi
  grep -qi microsoft /proc/version 2>/dev/null && return 0
  return 1
}

# ------------------------------------------------------------ record framework --
record() { results+=("$1|$2|$3|$4|$5|$6"); }
pass_check() { record "$1" "$2" OK "$3" "$4" ""; }
warn_check() { record "$1" "$2" WARN "$3" "$4" "$5"; }
fail_check() { record "$1" "$2" FAIL "$3" "$4" "$5"; }

# last recorded status for an id ("", OK, WARN, FAIL)
record_status() {
  local id="$1" status=""
  local r
  for r in "${results[@]}"; do
    IFS='|' read -r _ _ _ _ _ _ <<<"" # clear
    case "$r" in
      "$id|"*) IFS='|' read -r _ _ status _ _ _ <<<"$r" ;;
    esac
  done
  printf '%s' "$status"
}

# ------------------------------------------------------------ global checks --
check_g01_config_parses() {
  if [ "$HAVE_OPENCODE" = true ]; then
    local out rc
    out="$(opencode debug config 2>"$TMP_DIR/g01.err" || true)"
    rc=$?
    if [ $rc -ne 0 ]; then
      fail_check g01 FAIL "config parses" \
        "opencode debug config exited $rc: $(head -c 200 "$TMP_DIR/g01.err")" \
        "Fix the syntax error in your opencode config, then run \`opencode debug config\`."
      return
    fi
    if printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1; then
      printf '%s' "$out" > "$EFFECTIVE"
      pass_check g01 FAIL "config parses" "merges cleanly and is valid JSON"
    else
      fail_check g01 FAIL "config parses" \
        "opencode debug config returned non-JSON output" \
        "Fix your opencode config so \`opencode debug config\` prints valid JSON."
    fi
    return
  fi
  local cfg
  cfg="$(resolve_global_file)"
  if [ -n "$cfg" ]; then
    if strip_jsonc "$cfg" | python3 -m json.tool >/dev/null 2>&1; then
      strip_jsonc "$cfg" > "$EFFECTIVE"
      pass_check g01 WARN "config parses" "parsed from file (opencode not reachable)"
    else
      fail_check g01 FAIL "config parses" \
        "$cfg does not parse as JSON" \
        "Fix the syntax error in $cfg."
    fi
  else
    fail_check g01 FAIL "config parses" \
      "no opencode binary and no config file found" \
      "Install opencode or create ~/.config/opencode/opencode.json."
  fi
}

check_g02_model_resolvable() {
  local model small
  model="$(jsraw "$(eff_get "d.get('model','')")")"
  small="$(jsraw "$(eff_get "d.get('small_model','')")")"
  if [ -z "$model" ] && [ -z "$small" ]; then
    warn_check g02 WARN "models resolve" \
      "no model/small_model configured" \
      "Add model/small_model to your config."
    return
  fi
  if [ "$HAVE_OPENCODE" = false ]; then
    warn_check g02 WARN "models resolve" \
      "opencode unavailable — cannot cross-check '${model:-<none>}'" \
      "Install opencode to verify model ids."
    return
  fi
  local models missing
  models="$(opencode models 2>/dev/null | strip_ansi | sed 's/[[:space:]]*$//' || true)"
  missing=""
  [ -n "$model" ] && { grep -qxF "$model" <<<"$models" || missing="${missing}${model} "; }
  [ -n "$small" ] && { grep -qxF "$small" <<<"$models" || missing="${missing}${small} "; }
  if [ -n "$missing" ]; then
    warn_check g02 WARN "models resolve" \
      "not present in \`opencode models\`: ${missing// /, }" \
      "Double-check the model id and the provider config for it."
  else
    pass_check g02 WARN "models resolve" \
      "$([ -n "$model" ] && printf 'model=%s ' "$model")$([ -n "$small" ] && printf 'small=%s' "$small")"
  fi
}

check_g03_permission_default() {
  local def val
  def="$(eff_get "d.get('permission',{}).get('bash',{}).get('*','')")"
  val="$(jsraw "$def")"
  if [ -z "$val" ]; then
    fail_check g03 FAIL "permission default" \
      "no catch-all rule (\"*\":\"ask\"|\"deny\") in permission.bash" \
      "Add a default rule, e.g. \"*\": \"ask\". --fix can do this."
  elif [ "$val" = "ask" ] || [ "$val" = "deny" ]; then
    pass_check g03 FAIL "permission default" "permission.bash default is \"$val\""
  else
    warn_check g03 WARN "permission default" \
      "permission.bash default is \"$val\" (expected ask|deny)" \
      "Review whether an allow-all default is what you want."
  fi
}

check_g04_permission_footguns() {
  [ -s "$EFFECTIVE" ] || { skip g04 "permission footguns" "no effective config"; return; }
  eff_dict "d.get('permission',{}).get('bash',{})" > "$TMP_DIR/g04.txt"
  local found=0
  while IFS=$'\t' read -r pat val; do
    [ -n "$pat" ] || continue
    found=1
    case "$pat" in
      "rm -rf "*)
        if [ "$val" = "deny" ]; then
          pass_check g04 FAIL "permission footguns" "\"$pat\" is denied ✓"
        elif [ "$val" = "allow" ]; then
          warn_check g04 WARN "permission footguns" "\"$pat\" is ALLOWED — destructive" "Set \"rm -rf *\": \"deny\"."
        else
          warn_check g04 WARN "permission footguns" "\"$pat\" has no deny rule" "Add \"rm -rf *\": \"deny\"."
        fi ;;
      "git push --force"*)
        if [ "$val" = "deny" ]; then
          pass_check g04 FAIL "permission footguns" "\"$pat\" is denied ✓"
        elif [ "$val" = "allow" ]; then
          warn_check g04 WARN "permission footguns" "\"$pat\" is ALLOWED" "Set \"git push --force*\": \"deny\"."
        else
          warn_check g04 WARN "permission footguns" "\"$pat\" has no deny rule" "Add \"git push --force*\": \"deny\"."
        fi ;;
      "npm publish"*|"docker push"*|"gem publish"*|"pip publish"*)
        [ "$val" = "allow" ] && \
          warn_check g04 WARN "permission footguns" "\"$pat\" is allowed — publishing op" "Prefer asking: \"$pat\": \"ask\"." ;;
    esac
  done < "$TMP_DIR/g04.txt"
  if [ "$found" = 0 ]; then
    pass_check g04 FAIL "permission footguns" "no permission.bash rules block found"
  fi
}

check_g05_mcp_binaries() {
  local found=0
  while IFS=$'\t' read -r name entry; do
    [ -n "$name" ] || continue
    local type enabled cmd0
    type="$(jsraw "$(jsfield "$entry" "j.get('type','local')")")"
    [ "$type" = "remote" ] && continue
    enabled="$(jsraw "$(jsfield "$entry" "j.get('enabled',True)")")"
    case "$enabled" in True|true) : ;; *) continue ;; esac
    cmd0="$(jsraw "$(jsfield "$entry" "j.get('command',[''])[0] if isinstance(j.get('command'),list) else str(j.get('command',''))")")"
    [ -z "$cmd0" ] && continue
    found=1
    case "$cmd0" in
      */*)
        if [ -x "$cmd0" ]; then
          pass_check g05 FAIL "mcp binaries ($name)" "found: $cmd0"
        else
          fail_check g05 FAIL "mcp binaries ($name)" "command '$cmd0' is not an executable file" "Install it or fix the path."
        fi
        ;;
      npx|bunx|deno|uvx|pnpm|yarn|python3|python|node)
        pass_check g05 FAIL "mcp binaries ($name)" "launched via '$cmd0' (runtime)" ;;
      *) if command -v "$cmd0" >/dev/null 2>&1; then
           pass_check g05 FAIL "mcp binaries ($name)" "found: $cmd0"
         else
           fail_check g05 FAIL "mcp binaries ($name)" "command '$cmd0' not on PATH" "Install $cmd0 or fix the mcp command."
         fi ;;
    esac
  done < <(eff_dict "d.get('mcp',{})")
  if [ "$found" = 0 ]; then
    pass_check g05 FAIL "mcp binaries" "no local MCP servers configured"
  fi
}

check_g06_mcp_connectivity() {
  if [ "$HAVE_OPENCODE" = false ]; then
    skip g06 "mcp connectivity" "skipped (no opencode binary)"
    return
  fi
  local out connected failed
  out="$(opencode mcp list 2>&1 | strip_ansi || true)"
  connected="$(printf '%s\n' "$out" | grep -oE '✓ [^ ][^ ]*' | awk '{print $2}' | sort -u || true)"
  failed="$(printf '%s\n' "$out" | grep -oE '✗ [^ ][^ ]*' | awk '{print $2}' | sort -u || true)"
  local checked=0
  while IFS=$'\t' read -r name entry; do
    [ -n "$name" ] || continue
    local enabled
    enabled="$(jsraw "$(jsfield "$entry" "j.get('enabled',True)")")"
    case "$enabled" in True|true) : ;; *) continue ;; esac
    checked=1
    if grep -qxF "$name" <<<"$failed"; then
      fail_check g06 FAIL "mcp connectivity ($name)" \
        "server failed (see \`opencode mcp list\`)" \
        "Run \`opencode mcp debug $name\` and fix its config."
    elif grep -qxF "$name" <<<"$connected"; then
      pass_check g06 FAIL "mcp connectivity ($name)" "connected ✓"
    else
      skip g06 "mcp connectivity ($name)" "not reported by mcp list; unchecked"
    fi
  done < <(eff_dict "d.get('mcp',{})")
  if [ "$checked" = 0 ]; then
    pass_check g06 FAIL "mcp connectivity" "no enabled MCP servers in config"
  fi
}

check_g07_sandbox_browser() {
  local entry
  entry="$(eff_get "d.get('mcp',{}).get('agent-browser',{})")"
  [ -z "$entry" ] && { pass_check g07 FAIL "browser sandbox" "agent-browser MCP not configured"; return; }
  local enabled env val
  enabled="$(jsraw "$(jsfield "$entry" "j.get('enabled',True)")")"
  case "$enabled" in True|true) : ;; *) pass_check g07 FAIL "browser sandbox" "agent-browser MCP disabled"; return ;; esac
  env="$(jsfield "$entry" "j.get('environment',{})")"
  val="$(jsraw "$(jsfield "$env" "j.get('AGENT_BROWSER_ARGS','')")")"
  if is_vm && [[ "$val" != *--no-sandbox* ]]; then
    warn_check g07 FAIL "browser sandbox" \
      "agent-browser enabled in a container/VM/WSL without AGENT_BROWSER_ARGS=--no-sandbox — Chromium will crash with 'No usable sandbox'" \
      "Add environment {AGENT_BROWSER_ARGS: --no-sandbox}. --fix can do this."
  else
    local vd
    vd="$(printf '%s' "$val")"
    pass_check g07 FAIL "browser sandbox" \
      "environment AGENT_BROWSER_ARGS=$([ -n "$vd" ] && printf '%s' "$vd" || printf '(unset, VM?)')"
  fi
}

check_g08_plugin_paths() {
  local n=0
  while IFS=$'\t' read -r _ entry; do
    [ -z "$entry" ] && continue
    n=1
    local p
    p="$(jsraw "$(jsfield "$entry" "j if isinstance(j,str) else (j.get('dir','') if isinstance(j,dict) else '')")")"
    [ -z "$p" ] && continue
    case "$p" in
      /*|./*|../*)
        if [ -e "$p" ]; then
          pass_check g08 WARN "plugin paths ($p)" "exists"
        else
          fail_check g08 FAIL "plugin paths ($p)" "path missing" "Reinstall or fix the plugin path."
        fi ;;
      *) pass_check g08 WARN "plugin paths ($p)" "npm-style (runtime-managed)" ;;
    esac
  done < <(eff_dict "d.get('plugin',[])")
  if [ "$n" = 0 ]; then
    pass_check g08 WARN "plugin paths" "no plugins configured"
  fi
}

check_g09_skills_paths() {
  local found=0
  while IFS=$'\t' read -r _ entry; do
    [ -z "$entry" ] && continue
    found=1
    local p
    p="$(jsraw "$(jsfield "$entry" "j if isinstance(j,str) else (j.get('path','') if isinstance(j,dict) else '')")")"
    [ -z "$p" ] && continue
    if [ -d "$p" ] && find "$p" -maxdepth 3 -name SKILL.md | grep -q .; then
      pass_check g09 FAIL "skills path ($p)" "contains SKILL.md"
    elif [ -d "$p" ]; then
      fail_check g09 FAIL "skills path ($p)" "exists but no SKILL.md (depth ≤ 3)" "Check the layout (expects <dir>/<skill>/SKILL.md)."
    else
      fail_check g09 FAIL "skills path ($p)" "directory missing" "Reinstall the skills or fix skills.paths."
    fi
  done < <(eff_dict "d.get('skills',{}).get('paths',[]) if isinstance(d.get('skills'),dict) else d.get('skills',[])")
  if [ "$found" = 0 ]; then
    pass_check g09 FAIL "skills paths" "no skills.paths configured"
  fi
}

check_g10_instructions_refs() {
  local n=0
  while IFS=$'\t' read -r _ entry; do
    [ -z "$entry" ] && continue
    n=1
    local p
    p="$(jsraw "$(jsfield "$entry" "j if isinstance(j,str) else ''")")"
    [ -z "$p" ] && continue
    case "$p" in
      http:*|https:*|file:*|data:*) pass_check g10 FAIL "instruction ref ($p)" "external (not verified)"; continue ;;
    esac
    if [ -f "$p" ]; then
      pass_check g10 FAIL "instruction ref ($p)" "exists"
    elif [ -f "$GLOBAL_DIR/$p" ]; then
      pass_check g10 FAIL "instruction ref ($p)" "exists (relative to config dir)"
    else
      fail_check g10 FAIL "instruction ref ($p)" "file not found (cwd or config dir)" "Add the file or fix instructions."
    fi
  done < <(eff_dict "d.get('instructions',[])")
  if [ "$n" = 0 ]; then
    pass_check g10 FAIL "instructions refs" "no instructions configured"
  fi
}

check_g11_duplicate_ids() {
  local builtins=(build plan general explore scout help config mcp agents models version)
  local dup=0
  local d
  for d in agent command; do
    local dir="$GLOBAL_DIR/$d"
    [ -d "$dir" ] || continue
    local f
    for f in "$dir"/*.md; do
      [ -f "$f" ] || continue
      local id b
      id="$(basename "$f" .md)"
      for b in "${builtins[@]}"; do
        if [ "$id" = "$b" ]; then
          warn_check g11 WARN "duplicate ids" "$d/$id.md shadows the builtin '$id'" "Rename the file to avoid shadowing opencode's builtin $d."
          dup=1
        fi
      done
    done
  done
  if [ "$dup" = 0 ]; then
    pass_check g11 WARN "duplicate ids" "no agent/command ids collide with builtins"
  fi
}

# ------------------------------------------------------------ project checks --
resolve_project() {
  local dir="${1:-$PROJECT_DIR}"
  [ -n "$dir" ] || dir="$(pwd -P)"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -e "$dir/.opencode" ] || [ -e "$dir/opencode.json" ] || [ -e "$dir/opencode.jsonc" ]; then
      printf '%s' "$dir"
      return
    fi
    dir="$(dirname "$dir")"
  done
  printf '%s' "$1"
}

check_p01_project_config() {
  local root cfg
  root="$(resolve_project "${1:-}")"
  cfg=""
  [ -f "$root/opencode.jsonc" ] && cfg="$root/opencode.jsonc"
  [ -f "$root/opencode.json" ]  && cfg="$root/opencode.json"
  if [ -z "$cfg" ]; then
    if [ -d "$root/.opencode" ]; then
      pass_check p01 FAIL "project config" ".opencode/ present (config lives in global layer)"
    else
      skip p01 "project config" "no opencode.json(c) or .opencode/ found in $root"
    fi
    return
  fi
  if strip_jsonc "$cfg" | python3 -m json.tool >/dev/null 2>&1; then
    pass_check p01 FAIL "project config" "$cfg parses"
  else
    fail_check p01 FAIL "project config" "$cfg does not parse" "Fix the JSON/JSONC syntax error in $cfg."
  fi
}

check_md_frontmatter() { # $1 kind (agent|command)  $2 required-key
  local kind="$1" key="$2" root found f
  root="$(resolve_project "")"
  found=0
  for d in "$root/.opencode/$kind" "$root/.opencode/${kind}s"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.md; do
      [ -f "$f" ] || continue
      found=1
      local name id
      name="$(basename "$f")"
      id="${kind}-fm"
      if grep -qE "^${key}:" "$f"; then
        pass_check "$id" FAIL "${kind} frontmatter ($name)" "has $key: ✓"
      else
        fail_check "$id" FAIL "${kind} frontmatter ($name)" "missing '$key:' frontmatter" "Add '$key: <one-line description>' at the top of the file."
      fi
    done
  done
  if [ "$found" = 0 ]; then
    skip "p-frontmatter" "${kind} files" "no .opencode/${kind}(s) markdown found"
  fi
}

check_p02_agents_frontmatter() { check_md_frontmatter agent description; }
check_p03_commands_frontmatter() { check_md_frontmatter command description; }

check_p04_project_skills() {
  local root d found
  root="$(resolve_project "")"
  [ -d "$root/.opencode/skills" ] || { skip p04 "project skills" "no .opencode/skills dir"; return; }
  found=0
  for d in "$root/.opencode/skills"/*/; do
    [ -d "$d" ] || continue
    found=1
    if [ -f "$d/SKILL.md" ]; then
      pass_check p04 FAIL "project skills ($(basename "$d"))" "SKILL.md ✓"
    else
      fail_check p04 FAIL "project skills ($(basename "$d"))" "no SKILL.md" "Add a SKILL.md describing the skill."
    fi
  done
  if [ "$found" = 0 ]; then
    pass_check p04 FAIL "project skills" "skills dir empty"
  fi
}

check_p05_agents_md() {
  local root
  root="$(resolve_project "")"
  if [ -f "$root/AGENTS.md" ]; then
    pass_check p05 WARN "AGENTS.md" "present ✓"
  elif [ -d "$root/.opencode" ]; then
    warn_check p05 WARN "AGENTS.md" "no AGENTS.md in $root" "Add project rules at AGENTS.md (or .opencode/AGENTS.md)."
  else
    pass_check p05 WARN "AGENTS.md" "no project layer — global instructions only"
  fi
}

project_report() {
  local root
  root="$(resolve_project "")"
  if [ -d "$root/.opencode" ]; then info "project  : $root/.opencode"; fi
  if [ -f "$root/opencode.json" ];  then info "project  : $root/opencode.json";  fi
  if [ -f "$root/opencode.jsonc" ]; then info "project  : $root/opencode.jsonc"; fi
}

# --------------------------------------------------------------- env checks --
check_e01_opencode_installed() {
  if command -v opencode >/dev/null 2>&1; then
    local v
    v="$(opencode --version 2>/dev/null | sed 's/[[:space:]]*$//' | head -c 40)"
    HAVE_OPENCODE=true
    pass_check e01 FAIL "opencode binary" "v${v:-unknown}"
  else
    HAVE_OPENCODE=false
    fail_check e01 FAIL "opencode binary" "not on PATH" "Install opencode: see https://opencode.ai/docs/cli"
  fi
}

check_e02_version_latest() {
  if [ "$OFFLINE" = true ]; then
    skip e02 "version vs latest" "skipped (--offline)"
    return
  fi
  [ "$HAVE_OPENCODE" = false ] && { skip e02 "version vs latest" "skipped (no opencode)"; return; }
  local cur latest
  cur="$(opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  latest="$(curl -fsSL --max-time 8 https://api.github.com/repos/anomalyco/opencode/releases/latest 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tag_name","").lstrip("v"))
except Exception: sys.exit(1)' 2>/dev/null || true)"
  if [ -z "$cur" ]; then
    skip e02 "version vs latest" "could not read local version"
  elif [ -z "$latest" ]; then
    warn_check e02 WARN "version vs latest" "could not reach GitHub for latest version" "If you have network access, retry without --offline."
  else
    local a b c x y z
    IFS='.' read -r a b c <<<"$cur"
    IFS='.' read -r x y z <<<"$latest"
    if { [ "${a:-0}" -lt "${x:-0}" ]; } || { [ "${a:-0}" -eq "${x:-0}" ] && [ "${b:-0}" -lt "${y:-0}" ]; } || { [ "${a:-0}" -eq "${x:-0}" ] && [ "${b:-0}" -eq "${y:-0}" ] && [ "${c:-0}" -lt "${z:-0}" ]; }; then
      warn_check e02 WARN "version vs latest" "local v$cur < latest v$latest" "Upgrade: curl -fsSL https://opencode.ai/install | bash"
    else
      pass_check e02 WARN "version vs latest" "v$cur is current (latest v$latest)"
    fi
  fi
}

# ------------------------------------------------------------------- fixes --
fix_g03_default_permission() { # $1 config path
  python3 - "$1" <<'PY'
import json, re, sys
path = sys.argv[1]
src = open(path).read()
if re.search(r'"\*"\s*:\s*"(ask|deny)"', src):
    print("ALREADY"); sys.exit(0)
m = re.search(r'(?m)^(\s*)"bash"\s*:\s*\{\s*$', src)
if not m:
    print("NOBASH"); sys.exit(0)
ind = m.group(1) + '  '
at = src.index(m.group(0)) + len(m.group(0))
rest = src[at:]
# trailing comma only when another member follows (not an empty bash block)
trailing = "," if not re.match(r'[ \t]*\n?[ \t]*\}', rest) else ""
line = '\n' + ind + '"*": "ask"' + trailing
src = src[:at] + line + src[at:]
open(path, "w").write(src)
print("FIXED")
PY
}

# Rebuild the agent-browser entry canonically (type/command kept), injecting a
# comment-safe, comma-correct "environment" member. Any existing comments or
# extra keys inside the entry are dropped in the process.
fix_g07_sandbox() { # $1 config path
  python3 - "$1" <<'PY'
import json, re, sys
path = sys.argv[1]
src = open(path).read()
if re.search(r'"AGENT_BROWSER_ARGS"\s*:', src):
    print("ALREADY"); sys.exit(0)
m = re.search(r'(?m)^(\s*)"agent-browser"\s*:\s*\{\s*$', src)
if not m:
    print("NOENTRY"); sys.exit(0)
start = m.end()
depth = 0; close = None; i = start
while i < len(src):
    if src[i] == "{": depth += 1
    elif src[i] == "}":
        if depth == 0: close = i; break
        depth -= 1
    i += 1
if close is None:
    print("NOBLOCK"); sys.exit(0)
# capture trailing comma of the entry object if present
tail = src[close:]
has_comma = tail.startswith(",")
cmoff = 1 if tail.startswith(",") else 0
# read current values from the stripped entry (slice from the opening brace)
bstart = src.find("{", m.start())
entry_src = src[bstart:close+1]
try:
    stripped = entry_src
    # crude comment strip for the entry slice (strings-aware enough for keys)
    out=[];j=0;n=len(stripped);ins=False
    while j<n:
        c=stripped[j]
        if ins:
            out.append(c)
            if c=="\\" and j+1<n: out.append(stripped[j+1]); j+=2; continue
            if c=='"': ins=False
            j+=1; continue
        if c=='"': ins=True; out.append(c); j+=1; continue
        if c=="/" and j+1<n and stripped[j+1]=="/":
            k=stripped.find("\n",j); out.append("\n"); j=(n if k<0 else k+1); continue
        if c=="/" and j+1<n and stripped[j+1]=="*":
            k=stripped.find("*/",j+2); j=(n if k<0 else k+3); continue
        out.append(c); j+=1
    entry = json.loads("".join(out))
except Exception:
    print("UNPARSEABLE"); sys.exit(0)
cmd = entry.get("command", ["agent-browser", "mcp", "--tools", "core"])
ind = m.group(1)                       # indent of the entry key line
inner = ind + "  "
comma = "," if not has_comma else ""
block = (inner + '"environment": {\n' +
         inner + '  "AGENT_BROWSER_ARGS": "--no-sandbox"\n' +
         inner + '}' + comma + '\n')
new_entry = (m.group(0) + '\n' +
             inner + '"type": "local",\n' +
             inner + '"command": ' + json.dumps(cmd) + ',\n' +
             block +
             inner + '"enabled": true\n' +
             ind + '}' + ("," if has_comma else "") + '\n')
src = src[:m.start()] + new_entry + src[close+1+cmoff:]
open(path, "w").write(src)
print("FIXED")
PY
}

# verify JSON parse of a global config file after fixing
_json_ok() {
  strip_jsonc "$1" | python3 -m json.tool >/dev/null 2>&1
}

apply_fixes() {
  [ "$DO_FIX" = false ] && return
  if [ "$DRY_RUN" = true ]; then
    info ""
    info "Fix preview (--dry-run): no files will be written."
  fi
  local cfg ts fixg03=no fixg07=no
  cfg="$(resolve_global_file)"
  if [ -z "$cfg" ]; then
    warn "no global config file to fix"
    return
  fi
  [ "$(record_status g03)" != "OK" ] && fixg03=yes
  [ "$(record_status g07)" != "OK" ] && fixg07=yes
  [ "$fixg03" = no ] && [ "$fixg07" = no ] && { info "nothing to fix (g03/g07 already OK)"; return; }

  if [ "$DRY_RUN" = false ]; then
    if ! confirm "Apply fixes to $cfg?"; then
      err "fix cancelled"
      return 1
    fi
    ts="$(date +%Y%m%d%H%M%S)"
    run cp "$cfg" "$cfg.doctor.bak.$ts"
    FIX_CHANGED=true
  fi

  if [ "$fixg03" = yes ]; then
    local out
    [ "$DRY_RUN" = false ] && info "Fixing g03 (permission default)…"
    if [ "$DRY_RUN" = true ]; then
      printf "%b would insert \"*\": \"ask\" into permission.bash\n" "${C_DIM}•${C_RESET}"
      fixes_applied+=("g03|permission default|would insert default rule")
    else
      out="$(fix_g03_default_permission "$cfg")"
      case "$out" in
        FIXED)  ok "g03 fixed: inserted \"*\": \"ask\""; fixes_applied+=("g03|permission default|inserted default rule") ;;
        ALREADY) ok "g03 already fine" ;;
        *)      warn "g03 not fixed: $out" ;;
      esac
    fi
  fi
  if [ "$fixg07" = yes ]; then
    [ "$DRY_RUN" = false ] && info "Fixing g07 (browser sandbox)…"
    if [ "$DRY_RUN" = true ]; then
      printf "%b would add environment AGENT_BROWSER_ARGS=--no-sandbox to agent-browser\n" "${C_DIM}•${C_RESET}"
      fixes_applied+=("g07|browser sandbox|would add --no-sandbox env")
    else
      local out2
      out2="$(fix_g07_sandbox "$cfg")"
      case "$out2" in
        FIXED)   ok "g07 fixed: added AGENT_BROWSER_ARGS=--no-sandbox"; fixes_applied+=("g07|browser sandbox|added --no-sandbox env") ;;
        ALREADY) ok "g07 already fine" ;;
        *)       warn "g07 not fixed: $out2" ;;
      esac
    fi
  fi

  if [ "$DRY_RUN" = false ]; then
    if _json_ok "$cfg"; then
      ok "config still parses after fixes"
    else
      err "config does NOT parse after fixes — restoring backup $cfg.doctor.bak.$ts"
      run cp "$cfg.doctor.bak.$ts" "$cfg"
    fi
  fi
}

# ----------------------------------------------------------------- summary ---
emit_human() {
  emit_human_generate
  local ghrc=$?
  if [ "$ghrc" -eq 2 ]; then exit 2; fi
  if [ "$ghrc" -eq 1 ]; then exit 1; fi
  exit 0
}

emit_human_generate() {
  info ""
  info "Summary"
  local c_ok=0 c_warn=0 c_fail=0 rc=0
  local r id sev status name detail remedy
  for r in "${results[@]}"; do
    IFS='|' read -r id sev status name detail remedy <<<"$r"
    case "$status" in
      OK)
        c_ok=$((c_ok+1))
        [ "$VERBOSE" = true ] && printf "%b %b %s\n" "$B_OK" "${C_BOLD}$id${C_RESET}" "$name — $detail" ;;
      WARN)
        c_warn=$((c_warn+1))
        printf "%b %b %s\n" "$B_WARN" "${C_BOLD}$id${C_RESET}" "$name — $detail"
        [ -n "$remedy" ] && printf "         %b%s\n" "${C_DIM}" "→ $remedy" ;;
      FAIL)
        c_fail=$((c_fail+1))
        printf "%b %b %s\n" "$B_FAIL" "${C_BOLD}$id${C_RESET}" "$name — $detail"
        [ -n "$remedy" ] && printf "         %b%s\n" "${C_DIM}" "→ $remedy" ;;
    esac
  done
  local total=$((c_ok+c_warn+c_fail))
  local score=100
  [ "$total" -gt 0 ] && score=$(( (c_ok*100)/total ))
  printf "\n%b\n" "${C_BOLD}checks  :${C_RESET} $total   ${C_OK}ok:$c_ok${C_RESET}   ${C_WARN}warn:$c_warn${C_RESET}   ${C_ERR}fail:$c_fail${C_RESET}"
  printf "%b\n" "${C_BOLD}health  :${C_RESET} ${score}%"
  if [ "$c_fail" -gt 0 ]; then
    printf "%b\n" "${C_ERR}verdict : needs attention — fix failures, then re-run.${C_RESET}"
    rc=2
  elif [ "$c_warn" -gt 0 ]; then
    printf "%b\n" "${C_WARN}verdict : healthy with warnings — review the items above.${C_RESET}"
    rc=1
  else
    printf "%b\n" "${C_OK}verdict : all good.${C_RESET}"
    rc=0
  fi
  if [ "$DO_FIX" = true ] && [ "${#fixes_applied[@]}" -gt 0 ]; then
    printf "\n%b\n" "${C_BOLD}fixes$([ "$DRY_RUN" = true ] && printf ' (dry-run preview):' || printf ' applied:')${C_RESET}"
    local fx
    for fx in "${fixes_applied[@]}"; do
      IFS='|' read -r _ n a <<<"$fx"
      printf "  %b %s — %s\n" "${C_OK}✓${C_RESET}" "$n" "$a"
    done
    [ "$FIX_CHANGED" = true ] && info "backup: <config>.doctor.bak.<timestamp>"
  fi
  return $rc
}

emit_json() {
  local c_ok=0 c_warn=0 c_fail=0 body="" r id sev status name detail remedy
  for r in "${results[@]}"; do
    IFS='|' read -r id sev status name detail remedy <<<"$r"
    case "$status" in
      OK) c_ok=$((c_ok+1)) ;;
      WARN) c_warn=$((c_warn+1)) ;;
      FAIL) c_fail=$((c_fail+1)) ;;
    esac
    body+="$(printf '{"id":"%s","severity":"%s","status":"%s","name":"%s","detail":"%s","remedy":"%s"},' \
      "$(json_escape "$id")" "$(json_escape "$sev")" "$(json_escape "$status")" \
      "$(json_escape "$name")" "$(json_escape "$detail")" "$(json_escape "$remedy")")"
  done
  body="${body%,}"
  local total=$((c_ok+c_warn+c_fail)) score=100 exitc=0 fixes=""
  [ "$total" -gt 0 ] && score=$(( (c_ok*100)/total ))
  [ "$c_fail" -gt 0 ] && exitc=2
  [ "$c_warn" -gt 0 ] && [ "$exitc" = 0 ] && exitc=1
  local fx
  for fx in "${fixes_applied[@]}"; do
    IFS='|' read -r fid fname act <<<"$fx"
    fixes+="$(printf '{"id":"%s","name":"%s","action":"%s"},' \
      "$(json_escape "$fid")" "$(json_escape "$fname")" "$(json_escape "$act")")"
  done
  fixes="${fixes%,}"
  local online
  if [ "$OFFLINE" = true ]; then online=false; else online=true; fi
  printf '{"tool":"%s","version":"%s","scope":"%s","online":%s,"checks":[%s],"summary":{"total":%d,"ok":%d,"warn":%d,"fail":%d},"score":%d,"fixes_applied":[%s],"exit_code":%d}\n' \
    "$TOOL_NAME" "$DOC_VERSION" "$SCOPE" "$online" "$body" "$total" "$c_ok" "$c_warn" "$c_fail" "$score" "$fixes" "$exitc"
  return "$exitc"
}

# -------------------------------------------------------------------- main ---
main() {
  local i a n
  n="$#"
  for (( i=0; i<n; i++ )); do
    case "${1}" in
      --global) SCOPE=global; shift ;;
      --both) SCOPE=both; shift ;;
      --project) shift; PROJECT_DIR="${1:-}"; [ -n "$PROJECT_DIR" ] || die "--project needs a directory"; SCOPE=project ;;
      --json) JSON_MODE=true; shift ;;
      --offline) OFFLINE=true; shift ;;
      --fix) DO_FIX=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --verbose) VERBOSE=true; shift ;;
      -V|--version) version; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
  done

  need_cmd python3
  need_cmd grep

  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/doctor.XXXXXX")"
  EFFECTIVE="$TMP_DIR/effective.json"
  : > "$EFFECTIVE"
  trap 'rm -rf "$TMP_DIR"' EXIT

  banner
  info "Scope     : $SCOPE"
  info "Global    : $GLOBAL_DIR"
  [ -n "$PROJECT_DIR" ] && info "Project  : $PROJECT_DIR"

  # environment
  check_e01_opencode_installed
  check_e02_version_latest

  # global
  if [ "$SCOPE" = global ] || [ "$SCOPE" = both ]; then
    if [ "$HAVE_OPENCODE" = false ] && [ -z "$(resolve_global_file)" ]; then
      info "Global dir has no config file and opencode is missing — skipping global checks."
    else
      check_g01_config_parses
      check_g02_model_resolvable
      check_g03_permission_default
      check_g04_permission_footguns
      check_g05_mcp_binaries
      check_g06_mcp_connectivity
      check_g07_sandbox_browser
      check_g08_plugin_paths
      check_g09_skills_paths
      check_g10_instructions_refs
      check_g11_duplicate_ids
    fi
  fi

  # project
  if [ "$SCOPE" = project ] || [ "$SCOPE" = both ]; then
    project_report
    check_p01_project_config "${PROJECT_DIR:-}"
    check_p02_agents_frontmatter
    check_p03_commands_frontmatter
    check_p04_project_skills
    check_p05_agents_md
  fi

  apply_fixes || true

  if [ "$JSON_MODE" = true ]; then
    emit_json
    local json_rc=$?
    exit "$json_rc"
  fi
  emit_human
}

main "$@"