#!/bin/bash
# Sync all repos to configured branches and pull latest changes.
# Config file: sync_branches.yaml (same directory as this script)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/sync_branches.yaml}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}[ERROR] Config file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Parse workspace path from yaml
WS=$(grep "^workspace:" "$CONFIG_FILE" | awk '{print $2}')
SRC_DIR="${WS}/src"

if [[ ! -d "$SRC_DIR" ]]; then
    echo -e "${RED}[ERROR] src directory not found: $SRC_DIR${NC}"
    exit 1
fi

echo -e "${CYAN}=== Branch Sync: $SRC_DIR ===${NC}"
echo ""

# Parse branches section line by line
in_branches=false
success=0
failed=0
skipped=0

while IFS= read -r line; do
    # Detect start of branches block
    if [[ "$line" =~ ^branches: ]]; then
        in_branches=true
        continue
    fi

    # Only process lines under branches block
    if [[ "$in_branches" == true ]]; then
        # Skip empty lines and comments
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue

        # New top-level key signals end of branches block
        if [[ "$line" =~ ^[^[:space:]] && ! "$line" =~ ^branches: ]]; then
            in_branches=false
            continue
        fi

        # Parse "  repo_name: branch_name"
        repo=$(echo "$line" | sed 's/^[[:space:]]*//' | cut -d: -f1 | xargs)
        branch=$(echo "$line" | cut -d: -f2- | xargs)

        [[ -z "$repo" || -z "$branch" ]] && continue

        repo_path="$SRC_DIR/$repo"

        echo -e "${CYAN}[${repo}]${NC} → ${YELLOW}${branch}${NC}"

        if [[ ! -d "$repo_path/.git" ]]; then
            echo -e "  ${RED}SKIP: not a git repo${NC}"
            ((skipped++))
            continue
        fi

        # Check for uncommitted changes
        if ! git -C "$repo_path" diff --quiet 2>/dev/null || \
           ! git -C "$repo_path" diff --cached --quiet 2>/dev/null; then
            echo -e "  ${RED}SKIP: uncommitted changes detected${NC}"
            ((skipped++))
            continue
        fi

        # Switch branch
        current=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [[ "$current" != "$branch" ]]; then
            if git -C "$repo_path" checkout "$branch" 2>/dev/null; then
                echo -e "  ${GREEN}Switched: ${current} → ${branch}${NC}"
            else
                echo -e "  ${RED}FAIL: could not switch to '${branch}'${NC}"
                ((failed++))
                continue
            fi
        else
            echo -e "  Already on '${branch}'"
        fi

        # Pull latest
        pull_output=$(git -C "$repo_path" pull 2>&1)
        pull_exit=$?
        if [[ $pull_exit -eq 0 ]]; then
            if echo "$pull_output" | grep -qE "up to date|Already"; then
                echo -e "  ${GREEN}Up to date${NC}"
            else
                echo -e "  ${GREEN}Pulled latest changes${NC}"
            fi
        else
            echo -e "  ${RED}FAIL: pull failed${NC}"
            echo "  $pull_output"
            ((failed++))
            continue
        fi

        ((success++))
    fi
done < "$CONFIG_FILE"

echo ""
echo -e "${CYAN}=== Done: ${GREEN}${success} synced${NC}, ${YELLOW}${skipped} skipped${NC}, ${RED}${failed} failed${NC} ${CYAN}===${NC}"
