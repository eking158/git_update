#!/bin/bash

# ============================================================
# Repo update script
# Uses `--workspace`, `ROS_WS`, or interactive input to resolve the workspace.
#
# Usage:
#   ./update_repos.sh
#   ./update_repos.sh --workspace /home/aeirobot/ROS2/blackbox_ws
#   ROS_WS=/home/aeirobot/ROS2/blackbox_ws ./update_repos.sh --config blackbox
#   ./update_repos.sh --workspace /home/aeirobot/ROS2/alice4_develop_ws --config alice4_develop --repo alice_main,alice_common
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"

# ---- colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ---- parse arguments ----
FILTER_REPOS=()
FILTER_CONFIGS=()
WORKSPACE_INPUT=""
WORKSPACE_ROOT=""
SRC_DIR=""
WORKSPACE_SOURCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            IFS=',' read -ra FILTER_REPOS <<< "$2"
            shift 2
            ;;
        --config)
            IFS=',' read -ra FILTER_CONFIGS <<< "$2"
            shift 2
            ;;
        --workspace)
            WORKSPACE_INPUT="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# ---- scan available yaml files ----
AVAILABLE_YAMLS=()
while IFS= read -r -d '' f; do
    AVAILABLE_YAMLS+=("$f")
done < <(find "$CONFIG_DIR" -maxdepth 1 -name "*.yaml" -print0 | sort -z)

if [ ${#AVAILABLE_YAMLS[@]} -eq 0 ]; then
    echo -e "${RED}No config files found in ${CONFIG_DIR}${RESET}"
    exit 1
fi

# ---- helpers ----

# Parse "repo branch" pairs from a yaml without touching global state
parse_repos_from_yaml() {
    local cfg="$1"
    local in_branches=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^branches: ]]; then
            in_branches=true; continue
        fi
        if [[ "$in_branches" == true ]]; then
            [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$line" =~ ^[^[:space:]] ]]; then
                in_branches=false; continue
            fi
            local repo branch
            repo=$(echo "$line" | sed 's/^[[:space:]]*//' | cut -d: -f1 | xargs)
            branch=$(echo "$line" | cut -d: -f2- | xargs)
            [[ -n "$repo" && -n "$branch" ]] && echo "$repo $branch"
        fi
    done < "$cfg"
}

# Resolve workspace root and src directory once per run.
set_workspace_paths() {
    local candidate="$1"

    candidate="${candidate%/}"
    if [[ "$candidate" == */src ]]; then
        SRC_DIR="$candidate"
        WORKSPACE_ROOT="${candidate%/src}"
    else
        WORKSPACE_ROOT="$candidate"
        SRC_DIR="${candidate}/src"
    fi
}

pick_workspace() {
    local input=""

    echo ""
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo -e "${BOLD}  Step 1 / 3  —  Select workspace${RESET}"
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    if [ -n "$ROS_WS" ]; then
        echo -e "  ${BOLD}[Enter]${RESET} Use ${CYAN}ROS_WS${RESET}: ${DIM}${ROS_WS}${RESET}"
    fi
    echo -e "  Or type workspace path directly"
    echo -n "  > "

    read -r input
    if [ -z "$input" ] && [ -n "$ROS_WS" ]; then
        set_workspace_paths "$ROS_WS"
        WORKSPACE_SOURCE="ROS_WS"
        return 0
    fi

    if [ -n "$input" ]; then
        set_workspace_paths "$input"
        WORKSPACE_SOURCE="direct input"
        return 0
    fi

    echo -e "${RED}Workspace path is required. Set ROS_WS or enter a path.${RESET}"
    exit 1
}

resolve_workspace() {
    if [ -n "$WORKSPACE_INPUT" ]; then
        set_workspace_paths "$WORKSPACE_INPUT"
        WORKSPACE_SOURCE="--workspace"
        return 0
    fi

    if [ -t 0 ]; then
        pick_workspace
        return 0
    fi

    if [ -n "$ROS_WS" ]; then
        set_workspace_paths "$ROS_WS"
        WORKSPACE_SOURCE="ROS_WS"
        return 0
    fi

    echo -e "${RED}Workspace is not set. Use --workspace or export ROS_WS.${RESET}"
    exit 1
}

# ---- Step 2: config picker ----
pick_configs() {
    echo ""
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo -e "${BOLD}  Step 2 / 3  —  Select config${RESET}"
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo ""

    local i=1
    for yaml in "${AVAILABLE_YAMLS[@]}"; do
        local name
        name="$(basename "$yaml" .yaml)"
        printf "  ${BOLD}[%d]${RESET} %s\n" "$i" "$name"
        (( i++ ))
    done

    local total=${#AVAILABLE_YAMLS[@]}
    echo ""
    echo -e "  ${BOLD}[0]${RESET} All configs"
    echo ""
    echo -e "  Enter number(s) [0-${total}], space or comma separated"
    echo -n "  > "

    local input
    read -r input
    input="${input//,/ }"

    CONFIG_FILES=()
    local selected_all=false

    for token in $input; do
        if [[ "$token" == "0" ]]; then
            selected_all=true; break
        fi
        if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= total )); then
            CONFIG_FILES+=("${AVAILABLE_YAMLS[$((token - 1))]}")
        else
            echo -e "  ${YELLOW}Ignoring invalid input: '${token}'${RESET}"
        fi
    done

    if [ "$selected_all" = true ] || [ ${#CONFIG_FILES[@]} -eq 0 ]; then
        CONFIG_FILES=("${AVAILABLE_YAMLS[@]}")
        [ "$selected_all" = false ] && echo -e "  ${YELLOW}No valid selection — using all configs.${RESET}"
    fi

    # deduplicate while preserving order
    local seen=() deduped=()
    for f in "${CONFIG_FILES[@]}"; do
        local dup=false
        for s in "${seen[@]}"; do [ "$s" = "$f" ] && dup=true && break; done
        [ "$dup" = false ] && deduped+=("$f") && seen+=("$f")
    done
    CONFIG_FILES=("${deduped[@]}")
}

# ---- Step 3: repo picker ----
# Reads repos from CONFIG_FILES; sets FILTER_REPOS.
pick_repos() {
    # Collect all repos from selected configs (ordered, deduplicated)
    # Parallel arrays: PICK_REPOS, PICK_BRANCHES, PICK_CONFIG_NAMES
    local -a PICK_REPOS=()
    local -a PICK_BRANCHES=()
    local -a PICK_CONFIG_NAMES=()    # space-separated list of config names per repo
    declare -A _seen_repo

    for cfg in "${CONFIG_FILES[@]}"; do
        local cfgname; cfgname="$(basename "$cfg" .yaml)"
        while read -r repo branch; do
            if [[ -z "${_seen_repo[$repo]+x}" ]]; then
                PICK_REPOS+=("$repo")
                PICK_BRANCHES+=("$branch")
                PICK_CONFIG_NAMES+=("$cfgname")
                _seen_repo[$repo]=1
            else
                # repo appears in multiple configs — append config name
                local idx
                for idx in "${!PICK_REPOS[@]}"; do
                    if [[ "${PICK_REPOS[$idx]}" == "$repo" ]]; then
                        PICK_CONFIG_NAMES[$idx]+=" $cfgname"
                        break
                    fi
                done
            fi
        done < <(parse_repos_from_yaml "$cfg")
    done

    local total=${#PICK_REPOS[@]}
    if [ "$total" -eq 0 ]; then
        echo -e "${YELLOW}No repos found in selected configs.${RESET}"
        return
    fi

    local multi_config=false
    [ ${#CONFIG_FILES[@]} -gt 1 ] && multi_config=true

    echo ""
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo -e "${BOLD}  Step 3 / 3  —  Select repo(s)${RESET}"
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo ""

    for (( i=0; i<total; i++ )); do
        local repo="${PICK_REPOS[$i]}"
        local branch="${PICK_BRANCHES[$i]}"
        local cfg_names="${PICK_CONFIG_NAMES[$i]}"
        if [ "$multi_config" = true ]; then
            printf "  ${BOLD}[%d]${RESET} %-30s ${DIM}(%s)${RESET}\n" "$((i+1))" "$repo" "$cfg_names"
        else
            printf "  ${BOLD}[%d]${RESET} %-30s ${DIM}branch: %s${RESET}\n" "$((i+1))" "$repo" "$branch"
        fi
    done

    echo ""
    echo -e "  ${BOLD}[0]${RESET} All repos"
    echo ""
    echo -e "  Enter number(s) [0-${total}], space or comma separated"
    echo -n "  > "

    local input
    read -r input
    input="${input//,/ }"

    FILTER_REPOS=()
    local selected_all=false

    for token in $input; do
        if [[ "$token" == "0" ]]; then
            selected_all=true; break
        fi
        if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= total )); then
            FILTER_REPOS+=("${PICK_REPOS[$((token - 1))]}")
        else
            echo -e "  ${YELLOW}Ignoring invalid input: '${token}'${RESET}"
        fi
    done

    if [ "$selected_all" = true ] || [ ${#FILTER_REPOS[@]} -eq 0 ]; then
        FILTER_REPOS=()   # empty = all
        [ "$selected_all" = false ] && echo -e "  ${YELLOW}No valid selection — updating all repos.${RESET}"
    fi
}

# ---- resolve workspace ----
resolve_workspace

# ---- resolve CONFIG_FILES (Step 2) ----
CONFIG_FILES=()
if [ ${#FILTER_CONFIGS[@]} -gt 0 ]; then
    for name in "${FILTER_CONFIGS[@]}"; do
        if [[ "$name" == /* ]]; then
            CONFIG_FILES+=("$name")
        elif [[ "$name" == *.yaml ]]; then
            CONFIG_FILES+=("${CONFIG_DIR}/${name}")
        else
            CONFIG_FILES+=("${CONFIG_DIR}/${name}.yaml")
        fi
    done
elif [ ${#AVAILABLE_YAMLS[@]} -eq 1 ]; then
    CONFIG_FILES=("${AVAILABLE_YAMLS[0]}")
elif [ -t 0 ]; then
    pick_configs
else
    CONFIG_FILES=("${AVAILABLE_YAMLS[@]}")
fi

# ---- resolve FILTER_REPOS (Step 3) ----
# Only show repo picker in interactive mode when --repo was not given
if [ ${#FILTER_REPOS[@]} -eq 0 ] && [ -t 0 ]; then
    pick_repos
fi

# ---- global result buckets ----
ALL_SUCCESS=()
ALL_CLONED=()
ALL_FAILED=()
ALL_SKIPPED=()

# ---- git helpers ----

load_config() {
    local cfg="$1"
    GIT_BASE_URL_CFG=""
    unset REPO_BRANCH; declare -gA REPO_BRANCH

    local base
    base=$(grep "^git_base_url:" "$cfg" | awk '{print $2}')
    GIT_BASE_URL_CFG="${base:-${GIT_BASE_URL:-https://github.com/HERoEHS}}"

    local in_branches=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^branches: ]]; then
            in_branches=true; continue
        fi
        if [[ "$in_branches" == true ]]; then
            [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$line" =~ ^[^[:space:]] ]]; then
                in_branches=false; continue
            fi
            local repo branch
            repo=$(echo "$line" | sed 's/^[[:space:]]*//' | cut -d: -f1 | xargs)
            branch=$(echo "$line" | cut -d: -f2- | xargs)
            [[ -n "$repo" && -n "$branch" ]] && REPO_BRANCH["$repo"]="$branch"
        fi
    done < "$cfg"
}

get_clone_url() {
    echo "${GIT_BASE_URL_CFG%/}/${1}.git"
}

repo_has_local_changes() {
    local repo_path="$1"
    [ -n "$(git -C "$repo_path" status --porcelain --untracked-files=normal 2>/dev/null)" ]
}

clone_repo() {
    local repo="$1" target_branch="$2"
    local repo_path="${SRC_DIR}/${repo}"
    local clone_url; clone_url="$(get_clone_url "$repo")"

    if [ -e "$repo_path" ] && [ ! -d "$repo_path" ]; then
        echo -e "  ${RED}ERROR: path exists and is not a directory.${RESET}"
        ALL_FAILED+=("${repo}"); return 1
    fi
    if [ -d "$repo_path" ] && [ -n "$(find "$repo_path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        echo -e "  ${RED}ERROR: directory exists but is not a git repo.${RESET}"
        ALL_FAILED+=("${repo}"); return 1
    fi

    echo -e "  ${YELLOW}Not found locally, cloning...${RESET}"
    echo -e "  Clone URL: ${CYAN}${clone_url}${RESET}"

    local out; out=$(git clone --branch "$target_branch" --single-branch "$clone_url" "$repo_path" 2>&1)
    local status=$?
    echo "$out" | tail -1

    if [ $status -ne 0 ]; then
        echo -e "  ${RED}ERROR: clone failed.${RESET}"
        ALL_FAILED+=("${repo}"); return 1
    fi

    echo -e "  ${GREEN}Cloned → '${target_branch}'${RESET}"
    ALL_CLONED+=("${repo}"); ALL_SUCCESS+=("${repo}")
}

update_repo() {
    local repo="$1" target_branch="$2"
    local repo_path="${SRC_DIR}/${repo}"

    echo -e "${BOLD}[ ${repo} ]${RESET} → ${CYAN}${target_branch}${RESET}"

    if [ ! -d "${repo_path}/.git" ]; then
        clone_repo "$repo" "$target_branch"; return
    fi

    if repo_has_local_changes "$repo_path"; then
        echo -e "  ${YELLOW}SKIP: uncommitted or untracked local changes detected.${RESET}"
        ALL_SKIPPED+=("${repo}")
        return
    fi

    echo -n "  Fetching... "
    local fetch_out; fetch_out=$(git -C "$repo_path" fetch --prune origin 2>&1)
    local fetch_status=$?
    echo "$fetch_out" | tail -1
    if [ $fetch_status -ne 0 ]; then
        echo -e "  ${RED}ERROR: fetch failed.${RESET}"
        ALL_FAILED+=("${repo}"); return
    fi

    if ! git -C "$repo_path" ls-remote --exit-code --heads origin "$target_branch" > /dev/null 2>&1; then
        echo -e "  ${RED}ERROR: branch '${target_branch}' not found on remote.${RESET}"
        ALL_FAILED+=("${repo}"); return
    fi

    local current_branch; current_branch=$(git -C "$repo_path" branch --show-current)
    if [ "$current_branch" != "$target_branch" ]; then
        echo -n "  Switching ${current_branch} → ${target_branch}... "
        if ! git -C "$repo_path" checkout "$target_branch" 2>&1; then
            echo -e "  ${RED}ERROR: checkout failed.${RESET}"
            ALL_FAILED+=("${repo}"); return
        fi
    fi

    echo -n "  Pulling... "
    local pull_out; pull_out=$(git -C "$repo_path" pull origin "$target_branch" 2>&1)
    local pull_status=$?
    echo "$pull_out" | tail -1
    if [ $pull_status -ne 0 ]; then
        echo -e "  ${RED}ERROR: pull failed.${RESET}"
        ALL_FAILED+=("${repo}"); return
    fi

    echo -e "  ${GREEN}OK${RESET}"
    ALL_SUCCESS+=("${repo}")
}

print_workspace_header() {
    local cfg="$1" src="$2" base="$3"
    echo ""
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo -e "${BOLD}${CYAN}  $(basename "$cfg" .yaml)${RESET}"
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo -e "  Workspace  : ${WORKSPACE_ROOT}"
    echo -e "  Source dir : ${src}"
    echo -e "  Resolved by: ${WORKSPACE_SOURCE}"
    echo -e "  Git base   : ${base}"
    echo ""
}

print_summary() {
    echo ""
    echo -e "${BOLD}${CYAN}========================================"
    echo -e "  Overall Summary"
    echo -e "========================================${RESET}"
    [ ${#ALL_SUCCESS[@]} -gt 0 ] && echo -e "${GREEN}  SUCCESS (${#ALL_SUCCESS[@]}): ${ALL_SUCCESS[*]}${RESET}"
    [ ${#ALL_CLONED[@]}  -gt 0 ] && echo -e "${CYAN}  CLONED  (${#ALL_CLONED[@]}):  ${ALL_CLONED[*]}${RESET}"
    [ ${#ALL_FAILED[@]}  -gt 0 ] && echo -e "${RED}  FAILED  (${#ALL_FAILED[@]}):  ${ALL_FAILED[*]}${RESET}"
    [ ${#ALL_SKIPPED[@]} -gt 0 ] && echo -e "${YELLOW}  SKIPPED (${#ALL_SKIPPED[@]}): ${ALL_SKIPPED[*]}${RESET}"
    echo ""
}

# ---- main ----

for cfg in "${CONFIG_FILES[@]}"; do
    if [ ! -f "$cfg" ]; then
        echo -e "${RED}Config not found: ${cfg}${RESET}"
        continue
    fi

    load_config "$cfg"
    print_workspace_header "$cfg" "$SRC_DIR" "$GIT_BASE_URL_CFG"

    for repo in "${!REPO_BRANCH[@]}"; do
        if [ ${#FILTER_REPOS[@]} -gt 0 ]; then
            match=false
            for f in "${FILTER_REPOS[@]}"; do [ "$f" = "$repo" ] && match=true && break; done
            [ "$match" = false ] && continue
        fi
        update_repo "$repo" "${REPO_BRANCH[$repo]}"
        echo ""
    done
done

print_summary
