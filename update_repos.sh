#!/bin/bash

# ============================================================
# Repo update script for alice4_develop_ws/src
# 각 repo별 업데이트할 브랜치와 clone URL을 아래에서 설정하세요.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"
GIT_BASE_URL="${GIT_BASE_URL:-https://github.com/HERoEHS}"

declare -A REPO_BRANCH=(
    ["aeirobot_framework"]="develop"
    ["aeirobot_state_estimator"]="develop"
    ["aeirobot_toolbox"]="develop"
    ["alice_action_manager"]="develop"
    ["alice_common"]="develop"
    ["alice_main"]="develop"
    ["alice_parameters"]="develop"
    ["alice_simulation"]="develop"
)

# Optional per-repo clone URL override. If unset, uses:
#   ${GIT_BASE_URL}/${repo}.git
declare -A REPO_URL=(
)

# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

SUCCESS=()
FAILED=()
SKIPPED=()
CLONED=()

print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo -e "${BOLD}${CYAN}  alice_develop_ws repo updater${RESET}"
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo -e "  Source dir: ${SRC_DIR}"
    echo -e "  Clone base: ${GIT_BASE_URL}"
    echo ""
}

get_clone_url() {
    local repo="$1"

    if [ -n "${REPO_URL[$repo]}" ]; then
        echo "${REPO_URL[$repo]}"
    else
        echo "${GIT_BASE_URL%/}/${repo}.git"
    fi
}

clone_repo() {
    local repo="$1"
    local target_branch="$2"
    local repo_path="${SRC_DIR}/${repo}"
    local clone_url
    clone_url="$(get_clone_url "${repo}")"

    if [ -e "${repo_path}" ] && [ ! -d "${repo_path}" ]; then
        echo -e "  ${RED}ERROR: path exists and is not a directory.${RESET}"
        FAILED+=("${repo}")
        return 1
    fi

    if [ -d "${repo_path}" ] && [ -n "$(find "${repo_path}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        echo -e "  ${RED}ERROR: directory exists but is not a git repository.${RESET}"
        FAILED+=("${repo}")
        return 1
    fi

    echo -e "  ${YELLOW}Repository not found, cloning...${RESET}"
    echo -e "  Clone URL: ${CYAN}${clone_url}${RESET}"

    local clone_output
    clone_output=$(git clone --branch "${target_branch}" --single-branch "${clone_url}" "${repo_path}" 2>&1)
    local clone_status=$?
    echo "${clone_output}" | tail -1

    if [ ${clone_status} -ne 0 ]; then
        echo -e "  ${RED}ERROR: clone failed.${RESET}"
        FAILED+=("${repo}")
        return 1
    fi

    echo -e "  ${GREEN}Cloned and checked out '${target_branch}'${RESET}"
    CLONED+=("${repo}")
    SUCCESS+=("${repo}")
    return 0
}

update_repo() {
    local repo="$1"
    local target_branch="$2"
    local repo_path="${SRC_DIR}/${repo}"

    echo -e "${BOLD}[ ${repo} ]${RESET} → branch: ${CYAN}${target_branch}${RESET}"

    if [ ! -d "${repo_path}/.git" ]; then
        clone_repo "${repo}" "${target_branch}"
        return
    fi

    # stash uncommitted changes
    local stashed=false
    if ! git -C "${repo_path}" diff --quiet || ! git -C "${repo_path}" diff --cached --quiet; then
        echo -e "  ${YELLOW}Uncommitted changes detected, stashing...${RESET}"
        git -C "${repo_path}" stash push -m "auto-stash by update_repos.sh" --include-untracked > /dev/null 2>&1
        stashed=true
    fi

    # fetch
    echo -n "  Fetching... "
    local fetch_output
    fetch_output=$(git -C "${repo_path}" fetch --prune origin 2>&1)
    local fetch_status=$?
    echo "${fetch_output}" | tail -1
    if [ ${fetch_status} -ne 0 ]; then
        echo -e "  ${RED}ERROR: fetch failed.${RESET}"
        [ "$stashed" = true ] && git -C "${repo_path}" stash pop > /dev/null 2>&1
        FAILED+=("${repo}")
        return
    fi

    # check if target branch exists on remote
    if ! git -C "${repo_path}" ls-remote --exit-code --heads origin "${target_branch}" > /dev/null 2>&1; then
        echo -e "  ${RED}ERROR: branch '${target_branch}' not found on remote.${RESET}"
        [ "$stashed" = true ] && git -C "${repo_path}" stash pop > /dev/null 2>&1
        FAILED+=("${repo}")
        return
    fi

    # checkout target branch
    local current_branch
    current_branch=$(git -C "${repo_path}" branch --show-current)
    if [ "${current_branch}" != "${target_branch}" ]; then
        echo -n "  Switching ${current_branch} → ${target_branch}... "
        if ! git -C "${repo_path}" checkout "${target_branch}" 2>&1; then
            echo -e "  ${RED}ERROR: checkout failed.${RESET}"
            [ "$stashed" = true ] && git -C "${repo_path}" stash pop > /dev/null 2>&1
            FAILED+=("${repo}")
            return
        fi
    fi

    # pull
    echo -n "  Pulling... "
    local pull_output
    pull_output=$(git -C "${repo_path}" pull origin "${target_branch}" 2>&1)
    local pull_status=$?
    echo "${pull_output}" | tail -1

    if [ $pull_status -ne 0 ]; then
        echo -e "  ${RED}ERROR: pull failed.${RESET}"
        [ "$stashed" = true ] && git -C "${repo_path}" stash pop > /dev/null 2>&1
        FAILED+=("${repo}")
        return
    fi

    # restore stash
    if [ "$stashed" = true ]; then
        echo -n "  Restoring stash... "
        if git -C "${repo_path}" stash pop > /dev/null 2>&1; then
            echo -e "${GREEN}done${RESET}"
        else
            echo -e "${YELLOW}stash pop had conflicts — resolve manually${RESET}"
        fi
    fi

    echo -e "  ${GREEN}OK${RESET}"
    SUCCESS+=("${repo}")
}

print_summary() {
    echo ""
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo -e "${BOLD}  Summary${RESET}"
    echo -e "${BOLD}${CYAN}========================================${RESET}"

    if [ ${#SUCCESS[@]} -gt 0 ]; then
        echo -e "${GREEN}  SUCCESS (${#SUCCESS[@]}): ${SUCCESS[*]}${RESET}"
    fi
    if [ ${#CLONED[@]} -gt 0 ]; then
        echo -e "${CYAN}  CLONED  (${#CLONED[@]}): ${CLONED[*]}${RESET}"
    fi
    if [ ${#FAILED[@]} -gt 0 ]; then
        echo -e "${RED}  FAILED  (${#FAILED[@]}): ${FAILED[*]}${RESET}"
    fi
    if [ ${#SKIPPED[@]} -gt 0 ]; then
        echo -e "${YELLOW}  SKIPPED (${#SKIPPED[@]}): ${SKIPPED[*]}${RESET}"
    fi
    echo ""
}

# ---- main ----

print_header

# parse optional --repo filter: ./update_repos.sh --repo alice_main,alice_common
FILTER=()
if [[ "$1" == "--repo" && -n "$2" ]]; then
    IFS=',' read -ra FILTER <<< "$2"
fi

for repo in "${!REPO_BRANCH[@]}"; do
    if [ ${#FILTER[@]} -gt 0 ]; then
        match=false
        for f in "${FILTER[@]}"; do
            [ "$f" = "$repo" ] && match=true && break
        done
        [ "$match" = false ] && continue
    fi
    update_repo "${repo}" "${REPO_BRANCH[$repo]}"
    echo ""
done

print_summary
