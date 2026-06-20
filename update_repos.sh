#!/bin/bash

# ============================================================
# Repo update script
# Uses `file_path` in config, `--workspace`, `ROS_WS`, or interactive input.
#
# Usage:
#   ./update_repos.sh
#   ./update_repos.sh --workspace /home/aeirobot/ROS2/blackbox_ws
#   ROS_WS=/home/aeirobot/ROS2/blackbox_ws ./update_repos.sh --config blackbox
#   ./update_repos.sh --workspace /home/aeirobot/ROS2/alice4_develop_ws --config alice4_develop --repo alice_main,alice_common
#   ./update_repos.sh --develop-sync-mode merge --config blackbox
#
# Config example:
#   file_path: /home/aeirobot/ROS2/custom_src
#   git_base_url: https://github.com/HERoEHS
#   branches:
#     alice_main: develop
#     alice_parameters: main
#   git_base_url: https://github.com/eking
#   branches:
#     profile_settings: develop
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
DEFAULT_GIT_BASE_URL="${GIT_BASE_URL:-https://github.com/HERoEHS}"
GIT_BASE_SUMMARY=""
FALLBACK_WORKSPACE_ROOT=""
FALLBACK_SRC_DIR=""
FALLBACK_WORKSPACE_SOURCE=""
CONFIG_FILE_PATH=""
DEVELOP_SYNC_MODE=""
SELECTED_DEVELOP_SYNC_MODE=""

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
        --develop-sync-mode)
            DEVELOP_SYNC_MODE="$2"
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

expand_path_tokens() {
    local path="$1"

    path="${path/#\~/$HOME}"
    path="${path//\$\{HOME\}/$HOME}"
    path="${path//\$HOME/$HOME}"

    printf '%s\n' "$path"
}

build_clone_url_from_base() {
    local base="$1"
    local repo="$2"
    echo "${base%/}/${repo}.git"
}

get_git_base_summary() {
    local cfg="$1"
    local -a bases=()
    local -a unique_bases=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        local trimmed base seen=false
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
        [[ -z "$trimmed" || "$trimmed" =~ ^# ]] && continue

        if [[ "$trimmed" =~ ^git_base_url: ]]; then
            base=$(echo "$trimmed" | cut -d: -f2- | xargs)
            [[ -z "$base" ]] && continue
            for existing in "${unique_bases[@]}"; do
                if [[ "$existing" == "$base" ]]; then
                    seen=true
                    break
                fi
            done
            if [[ "$seen" == false ]]; then
                unique_bases+=("$base")
            fi
        fi
    done < "$cfg"

    if (( ${#unique_bases[@]} == 0 )); then
        echo "$DEFAULT_GIT_BASE_URL"
    elif (( ${#unique_bases[@]} == 1 )); then
        echo "${unique_bases[0]}"
    else
        echo "mixed (per section/repo)"
    fi
}

get_config_file_path() {
    local cfg="$1"

    while IFS= read -r line || [[ -n "$line" ]]; do
        local trimmed indent path
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
        indent=$(( ${#line} - ${#trimmed} ))
        [[ -z "$trimmed" || "$trimmed" =~ ^# ]] && continue

        if (( indent == 0 )) && [[ "$trimmed" =~ ^file_path: ]]; then
            path=$(echo "$trimmed" | cut -d: -f2- | xargs)
            if [[ -n "$path" ]]; then
                path="$(expand_path_tokens "$path")"
                echo "$path"
                return 0
            fi
        fi
    done < "$cfg"

    return 1
}

# Parse repo entries from yaml.
# Output: <repo>\t<branch>\t<clone_url_override>
parse_repo_entries_from_yaml() {
    local cfg="$1"
    local in_branches=false
    local current_section_git_base_url=""
    local current_repo=""
    local current_branch=""
    local current_clone_url=""
    local current_repo_git_base_url=""

    flush_current_repo_entry() {
        local effective_clone_url="$current_clone_url"
        local effective_git_base_url="$current_repo_git_base_url"

        if [[ -z "$effective_git_base_url" ]]; then
            effective_git_base_url="$current_section_git_base_url"
        fi

        if [[ -z "$effective_clone_url" && -n "$effective_git_base_url" ]]; then
            effective_clone_url="$(build_clone_url_from_base "$effective_git_base_url" "$current_repo")"
        fi
        if [[ -n "$current_repo" && -n "$current_branch" ]]; then
            printf "%s\t%s\t%s\n" "$current_repo" "$current_branch" "$effective_clone_url"
        fi
        current_repo=""
        current_branch=""
        current_clone_url=""
        current_repo_git_base_url=""
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        local trimmed indent key value

        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
        indent=$(( ${#line} - ${#trimmed} ))

        [[ -z "$trimmed" || "$trimmed" =~ ^# ]] && continue

        if (( indent == 0 )); then
            if [[ "$trimmed" =~ ^git_base_url: ]]; then
                flush_current_repo_entry
                current_section_git_base_url=$(echo "$trimmed" | cut -d: -f2- | xargs)
                in_branches=false
                continue
            fi

            if [[ "$trimmed" =~ ^branches: ]]; then
                flush_current_repo_entry
                in_branches=true
                continue
            fi

            flush_current_repo_entry
            in_branches=false
            continue
        fi

        if [[ "$in_branches" != true ]]; then
            continue
        fi

        if (( indent == 2 )); then
            flush_current_repo_entry

            current_repo=$(echo "$trimmed" | cut -d: -f1 | xargs)
            value=$(echo "$trimmed" | cut -d: -f2- | xargs)

            if [[ -n "$value" ]]; then
                current_branch="$value"
                flush_current_repo_entry
            fi
            continue
        fi

        if (( indent >= 4 )) && [[ -n "$current_repo" ]]; then
            key=$(echo "$trimmed" | cut -d: -f1 | xargs)
            value=$(echo "$trimmed" | cut -d: -f2- | xargs)
            case "$key" in
                branch)
                    current_branch="$value"
                    ;;
                git_url|clone_url|url)
                    current_clone_url="$value"
                    ;;
                git_base_url)
                    current_repo_git_base_url="$value"
                    ;;
            esac
        fi
    done < "$cfg"

    flush_current_repo_entry
}

# Parse "repo branch" pairs from a yaml without touching global state
parse_repos_from_yaml() {
    local cfg="$1"
    while IFS=$'\t' read -r repo branch _clone_url; do
        [[ -n "$repo" && -n "$branch" ]] && printf "%s %s\n" "$repo" "$branch"
    done < <(parse_repo_entries_from_yaml "$cfg")
}

# Resolve workspace root and src directory once per run.
set_workspace_paths() {
    local candidate="$1"

    candidate="$(expand_path_tokens "$candidate")"
    candidate="${candidate%/}"
    if [[ "$candidate" == */src ]]; then
        SRC_DIR="$candidate"
        WORKSPACE_ROOT="${candidate%/src}"
    else
        WORKSPACE_ROOT="$candidate"
        SRC_DIR="${candidate}/src"
    fi
}

set_source_dir_path() {
    local candidate="$1"

    candidate="$(expand_path_tokens "$candidate")"
    SRC_DIR="${candidate%/}"
    WORKSPACE_ROOT=""
}

pick_workspace() {
    local input=""

    echo ""
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo -e "${BOLD}  Select workspace${RESET}"
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo -e "  ${DIM}(used only when selected config does not define file_path)${RESET}"
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
    elif [ -t 0 ]; then
        pick_workspace
    elif [ -n "$ROS_WS" ]; then
        set_workspace_paths "$ROS_WS"
        WORKSPACE_SOURCE="ROS_WS"
    else
        echo -e "${RED}Workspace is not set. Use --workspace or export ROS_WS.${RESET}"
        exit 1
    fi

    FALLBACK_WORKSPACE_ROOT="$WORKSPACE_ROOT"
    FALLBACK_SRC_DIR="$SRC_DIR"
    FALLBACK_WORKSPACE_SOURCE="$WORKSPACE_SOURCE"
}

# ---- config picker ----
pick_configs() {
    echo ""
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo -e "${BOLD}  Select config${RESET}"
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

# ---- repo picker ----
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
    echo -e "${BOLD}  Select repo(s)${RESET}"
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

# ---- resolve CONFIG_FILES ----
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

# ---- resolve workspace fallback when needed ----
CONFIGS_NEED_WORKSPACE=false
for cfg in "${CONFIG_FILES[@]}"; do
    if ! get_config_file_path "$cfg" > /dev/null; then
        CONFIGS_NEED_WORKSPACE=true
        break
    fi
done

if [ "$CONFIGS_NEED_WORKSPACE" = true ]; then
    resolve_workspace
fi

# ---- resolve FILTER_REPOS ----
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
    GIT_BASE_URL_CFG="$DEFAULT_GIT_BASE_URL"
    GIT_BASE_SUMMARY="$(get_git_base_summary "$cfg")"
    CONFIG_FILE_PATH="$(get_config_file_path "$cfg" || true)"
    unset REPO_BRANCH; declare -gA REPO_BRANCH
    unset REPO_CLONE_URL; declare -gA REPO_CLONE_URL

    local repo branch clone_url
    while IFS=$'\t' read -r repo branch clone_url; do
        [[ -z "$repo" || -z "$branch" ]] && continue
        REPO_BRANCH["$repo"]="$branch"
        if [[ -n "$clone_url" ]]; then
            REPO_CLONE_URL["$repo"]="$clone_url"
        fi
    done < <(parse_repo_entries_from_yaml "$cfg")
}

ensure_source_dir_exists() {
    if [ -d "$SRC_DIR" ]; then
        return 0
    fi

    if [ -e "$SRC_DIR" ]; then
        echo -e "${RED}Target path exists but is not a directory: ${SRC_DIR}${RESET}"
        return 1
    fi

    if [ ! -t 0 ]; then
        echo -e "${RED}Target directory does not exist: ${SRC_DIR}${RESET}"
        echo -e "${RED}Run interactively to create it, or create it manually first.${RESET}"
        return 1
    fi

    echo ""
    echo -e "${YELLOW}Target directory does not exist:${RESET} ${SRC_DIR}"
    echo -n "Create it now? [y/N] "

    local answer=""
    read -r answer

    case "$answer" in
        y|Y|yes|YES|Yes)
            if ! mkdir -p "$SRC_DIR"; then
                echo -e "${RED}Failed to create directory: ${SRC_DIR}${RESET}"
                return 1
            fi
            echo -e "${GREEN}Created directory:${RESET} ${SRC_DIR}"
            ;;
        *)
            echo -e "${YELLOW}Skipping because target directory was not created.${RESET}"
            return 1
            ;;
    esac

    return 0
}

resolve_source_dir_for_config() {
    if [ -n "$CONFIG_FILE_PATH" ]; then
        set_source_dir_path "$CONFIG_FILE_PATH"
        WORKSPACE_SOURCE="file_path in config"
    else
        if [ -z "$FALLBACK_SRC_DIR" ]; then
            echo -e "${RED}No workspace or file_path is available for this config.${RESET}"
            return 1
        fi
        SRC_DIR="$FALLBACK_SRC_DIR"
        WORKSPACE_ROOT="$FALLBACK_WORKSPACE_ROOT"
        WORKSPACE_SOURCE="$FALLBACK_WORKSPACE_SOURCE"
    fi

    ensure_source_dir_exists
}

get_clone_url() {
    local repo="$1"
    if [[ -n "${REPO_CLONE_URL[$repo]}" ]]; then
        echo "${REPO_CLONE_URL[$repo]}"
        return 0
    fi
    build_clone_url_from_base "$GIT_BASE_URL_CFG" "$repo"
}

ensure_origin_url() {
    local repo="$1"
    local repo_path="$2"
    local desired_clone_url="${REPO_CLONE_URL[$repo]}"

    if [[ -z "$desired_clone_url" ]]; then
        return 0
    fi

    local current_origin_url=""
    current_origin_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)

    if [[ "$current_origin_url" == "$desired_clone_url" ]]; then
        return 0
    fi

    echo -n "  Syncing origin URL... "
    local out status=0
    if [[ -n "$current_origin_url" ]]; then
        out=$(git -C "$repo_path" remote set-url origin "$desired_clone_url" 2>&1) || status=$?
    else
        out=$(git -C "$repo_path" remote add origin "$desired_clone_url" 2>&1) || status=$?
    fi

    if [[ $status -ne 0 ]]; then
        echo "${out}" | tail -1
        echo -e "  ${RED}ERROR: failed to update origin URL.${RESET}"
        ALL_FAILED+=("${repo}")
        return 1
    fi

    echo -e "${GREEN}OK${RESET}"
}

choose_develop_sync_mode() {
    local repo="$1"
    local current_branch="$2"

    if [[ -n "$DEVELOP_SYNC_MODE" ]]; then
        case "$DEVELOP_SYNC_MODE" in
            merge|rebase|skip)
                SELECTED_DEVELOP_SYNC_MODE="$DEVELOP_SYNC_MODE"
                return 0
                ;;
            *)
                echo -e "  ${RED}ERROR: invalid --develop-sync-mode '${DEVELOP_SYNC_MODE}'. Use merge, rebase, or skip.${RESET}"
                ALL_FAILED+=("${repo}")
                return 1
                ;;
        esac
    fi

    if [ ! -t 0 ]; then
        echo -e "  ${YELLOW}Target branch is 'develop' while current branch is '${current_branch}'.${RESET}"
        echo -e "  ${YELLOW}Non-interactive mode requires --develop-sync-mode merge|rebase|skip. Skipping.${RESET}"
        SELECTED_DEVELOP_SYNC_MODE="skip"
        return 0
    fi

    echo -e "  ${YELLOW}Target branch is 'develop' while current branch is '${current_branch}'.${RESET}"
    echo -e "  Choose how to bring latest develop into the current branch:"
    echo -e "    ${BOLD}[1]${RESET} merge ${DIM}(recommended)${RESET}"
    echo -e "    ${BOLD}[2]${RESET} rebase"
    echo -e "    ${BOLD}[0]${RESET} skip"
    echo -n "  > "

    local input=""
    read -r input

    case "$input" in
        1|merge|MERGE|Merge)
            SELECTED_DEVELOP_SYNC_MODE="merge"
            ;;
        2|rebase|REBASE|Rebase)
            SELECTED_DEVELOP_SYNC_MODE="rebase"
            ;;
        0|skip|SKIP|Skip|"")
            SELECTED_DEVELOP_SYNC_MODE="skip"
            ;;
        *)
            echo -e "  ${YELLOW}Unknown selection '${input}', skipping.${RESET}"
            SELECTED_DEVELOP_SYNC_MODE="skip"
            ;;
    esac
}

sync_current_branch_with_develop() {
    local repo="$1"
    local repo_path="$2"
    local current_branch="$3"
    local mode="$4"

    if [[ "$mode" == "skip" ]]; then
        echo -e "  ${YELLOW}SKIP: develop sync was skipped by user selection.${RESET}"
        ALL_SKIPPED+=("${repo}")
        return 2
    fi

    echo -n "  Fetching develop ref... "
    local out status=0
    out=$(git -C "$repo_path" fetch origin develop 2>&1) || status=$?
    if [[ $status -ne 0 ]]; then
        echo "${out}" | tail -1
        echo -e "  ${RED}ERROR: failed to fetch develop.${RESET}"
        ALL_FAILED+=("${repo}")
        return 1
    fi
    echo -e "${GREEN}OK${RESET}"

    case "$mode" in
        merge)
            echo -n "  Merging develop into ${current_branch}... "
            out=$(git -C "$repo_path" merge --no-edit FETCH_HEAD 2>&1) || status=$?
            ;;
        rebase)
            echo -n "  Rebasing ${current_branch} onto develop... "
            out=$(git -C "$repo_path" rebase FETCH_HEAD 2>&1) || status=$?
            ;;
        *)
            echo -e "  ${RED}ERROR: unsupported develop sync mode '${mode}'.${RESET}"
            ALL_FAILED+=("${repo}")
            return 1
            ;;
    esac

    if [[ $status -ne 0 ]]; then
        echo "${out}" | tail -1
        echo -e "  ${RED}ERROR: ${mode} failed. Resolve conflicts manually if needed.${RESET}"
        ALL_FAILED+=("${repo}")
        return 1
    fi

    echo "$out" | tail -1
    echo -e "  ${GREEN}OK${RESET}"
    return 0
}

switch_to_target_branch() {
    local repo="$1"
    local repo_path="$2"
    local target_branch="$3"
    local current_branch="$4"
    local label="$current_branch"

    if [[ -z "$label" ]]; then
        label="detached HEAD"
    fi

    echo -n "  Switching ${label} → ${target_branch}... "

    local out status=0
    if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$target_branch"; then
        out=$(git -C "$repo_path" checkout "$target_branch" 2>&1) || status=$?
    else
        echo -n "  Fetching target branch ref... "
        out=$(git -C "$repo_path" fetch origin "$target_branch" 2>&1) || status=$?
        if [[ $status -ne 0 ]]; then
            echo "${out}" | tail -1
            echo -e "  ${RED}ERROR: failed to fetch target branch ref.${RESET}"
            ALL_FAILED+=("${repo}")
            return 1
        fi
        echo -e "${GREEN}OK${RESET}"

        out=$(git -C "$repo_path" checkout -b "$target_branch" FETCH_HEAD 2>&1) || status=$?
    fi

    if [[ $status -ne 0 ]]; then
        echo "${out}" | tail -1
        echo -e "  ${RED}ERROR: checkout failed.${RESET}"
        ALL_FAILED+=("${repo}")
        return 1
    fi

    echo -e "${GREEN}OK${RESET}"
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

    if ! ensure_origin_url "$repo" "$repo_path"; then
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

    local current_branch; current_branch=$(git -C "$repo_path" branch --show-current)
    if [ "$current_branch" != "$target_branch" ]; then
        if [[ "$target_branch" == "develop" && -n "$current_branch" ]]; then
            if ! choose_develop_sync_mode "$repo" "$current_branch"; then
                return
            fi

            sync_current_branch_with_develop "$repo" "$repo_path" "$current_branch" "$SELECTED_DEVELOP_SYNC_MODE"
            local develop_sync_status=$?
            if [[ $develop_sync_status -eq 2 ]]; then
                return
            fi
            if [[ $develop_sync_status -ne 0 ]]; then
                return
            fi

            ALL_SUCCESS+=("${repo}")
            return
        else
            if ! git -C "$repo_path" ls-remote --exit-code --heads origin "$target_branch" > /dev/null 2>&1; then
                echo -e "  ${RED}ERROR: branch '${target_branch}' not found on remote.${RESET}"
                ALL_FAILED+=("${repo}"); return
            fi

            if ! switch_to_target_branch "$repo" "$repo_path" "$target_branch" "$current_branch"; then
                return
            fi
        fi
    fi

    if ! git -C "$repo_path" ls-remote --exit-code --heads origin "$target_branch" > /dev/null 2>&1; then
        echo -e "  ${RED}ERROR: branch '${target_branch}' not found on remote.${RESET}"
        ALL_FAILED+=("${repo}"); return
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
    if [ -n "$WORKSPACE_ROOT" ]; then
        echo -e "  Workspace  : ${WORKSPACE_ROOT}"
    fi
    echo -e "  Source dir : ${src}"
    echo -e "  Resolved by: ${WORKSPACE_SOURCE}"
    echo -e "  Git base   : ${GIT_BASE_SUMMARY}"
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
    if ! resolve_source_dir_for_config; then
        echo ""
        continue
    fi
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
