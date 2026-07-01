# git_update

`update_repos.sh`는 ROS workspace 안의 여러 git repo를 한 번에 관리하기 위한 스크립트입니다.

이 스크립트로 다음 작업을 할 수 있습니다.

- 없는 repo를 `<workspace>/src` 아래에 clone
- `file_path`가 있으면 해당 경로에 바로 clone
- 이미 있는 repo를 `fetch` + `pull`로 업데이트
- 특정 repo를 제외하고 나머지만 일괄 clone/pull 가능
- branch가 다를 때는 `대상 branch로 전환 후 pull` 또는 `현재 branch에서 대상 branch를 바로 pull` 중 선택 가능
- branch 전환이 로컬 변경 때문에 막히면, skip 전에 현재 branch에서 대상 branch를 한 번 더 pull 시도
- branch 전환이 `.git/index.lock` 때문에 막히면, stale lock 파일을 삭제한 뒤 branch 전환 재시도
- Git이 로컬 변경 사항 때문에 실제로 진행을 막는 경우에만 skip
- 하나의 config 파일 안에서 서로 다른 git base URL 사용

## 위치

- Script: `update_repos.sh`
- Configs: `config/*.yaml`

## Workspace 결정 순서

workspace는 아래 순서로 결정됩니다.

1. config의 `file_path`
2. `--workspace <path>`
3. 실행 중 직접 입력
4. `ROS_WS` 환경 변수

workspace root를 넘기면 내부적으로 `<workspace>/src`를 사용합니다.
이미 `/src` 경로를 넘기면 그 경로를 그대로 사용합니다.
config에 `file_path`가 있으면 workspace를 묻지 않고 해당 경로를 그대로 사용합니다.
경로에는 `$HOME`, `${HOME}`, `~`를 사용할 수 있습니다.

## 기본 사용법

대화형 실행:

```bash
./update_repos.sh
```

`Select repo(s)` 입력 예시:

- `0`: 전체 repo 실행
- `1 3 5`: 선택한 repo만 실행
- `-2 5`: 2번, 5번 repo를 제외하고 나머지 실행

`ROS_WS` 사용:

```bash
export ROS_WS=/home/aeirobot/ROS2/blackbox_ws
./update_repos.sh --config blackbox
```

workspace 경로 직접 지정:

```bash
./update_repos.sh --workspace /home/aeirobot/ROS2/blackbox_ws --config blackbox
```

특정 repo만 업데이트:

```bash
./update_repos.sh --workspace /home/aeirobot/ROS2/alice_mobile_ws --config alice_mobile_develop --repo alice_mobile_main,alice_mobile_parameters
```

특정 repo만 제외하고 나머지 업데이트:

```bash
./update_repos.sh --workspace /home/aeirobot/ROS2/alice_mobile_ws --config alice_mobile_develop --exclude-repo alice_mobile_parameters,alice_mobile_gui
```

branch mismatch 처리 방식을 미리 지정:

```bash
./update_repos.sh --branch-mismatch-mode pull-current --config blackbox
```

`develop`을 현재 branch로 가져올 때 sync 방식을 미리 지정:

```bash
./update_repos.sh --develop-sync-mode merge --branch-mismatch-mode pull-current --config blackbox
```

## Config 형식

### 1. 단일 Git Base URL 사용

```yaml
git_base_url: https://github.com/HERoEHS

branches:
  aeirobot_framework: develop
  alice_main: develop
  alice_parameters: main
```

위 형식은 각 repo를 아래 주소로 해석합니다.

```text
<git_base_url>/<repo>.git
```

예:

```text
https://github.com/HERoEHS/alice_main.git
```

### 2. `file_path` 직접 지정

```yaml
file_path: /home/aeirobot/ROS2/custom_target_src

git_base_url: https://github.com/HERoEHS

branches:
  alice_main: develop
  alice_parameters: main
```

이 형식에서는 repo가 `<workspace>/src`가 아니라 `file_path` 아래에 바로 clone 또는 update됩니다.

예:

```text
/home/aeirobot/ROS2/custom_target_src/alice_main
```

`file_path` 경로가 아직 없으면, 대화형 실행에서는 폴더를 생성할지 물어봅니다.
비대화형 실행에서는 자동 생성하지 않고 에러를 출력합니다.
`file_path`에도 `$HOME`, `${HOME}`, `~`를 사용할 수 있습니다.

### 3. 하나의 파일에서 여러 Git Base URL 사용

```yaml
git_base_url: https://github.com/HERoEHS

branches:
  aeirobot_framework: develop
  aeirobot_toolbox: feature/m1_poc_hand_rad
  alice_mobile_common: develop
  alice_mobile_main: develop

git_base_url: https://github.com/eking

branches:
  profile_settings: develop
```

이 형식에서는 각 `branches:` 블록이 바로 위에 선언된 `git_base_url`을 사용합니다.

### 4. repo별 개별 URL override

필요하면 특정 repo만 직접 URL을 지정할 수도 있습니다.

```yaml
git_base_url: https://github.com/HERoEHS

branches:
  alice_main: develop
  custom_repo:
    branch: main
    git_url: git@github.com:other-org/custom_repo.git
```

repo별로 사용할 수 있는 키는 아래와 같습니다.

- `branch`
- `git_url`
- `clone_url`
- `url`
- `git_base_url`

## Config 관련 참고

- 이 형식은 `update_repos.sh` 전용 config 형식입니다.
- 하나의 파일 안에서 `git_base_url:`를 여러 번 쓰는 것을 이 스크립트는 지원합니다.
- `file_path:`는 top-level에서 읽으며, 해당 config 전체의 target directory로 사용됩니다.
- 일반적인 YAML parser에서는 중복 top-level key를 다르게 처리할 수 있으므로, 다른 YAML 도구와 공용으로 쓰는 용도에는 적합하지 않을 수 있습니다.

## 업데이트 동작

각 repo마다 아래 순서로 동작합니다.

1. 로컬에 repo가 없으면 clone
2. repo가 이미 있으면 먼저 `git fetch --prune origin`
3. 현재 branch가 다르면 원격에 대상 branch가 있는지 먼저 확인
4. `--exclude-repo`에 포함된 repo는 clone/pull 없이 바로 skip
5. branch mismatch가 있으면 사용자가 아래 중 하나를 선택
   - 대상 branch로 전환한 뒤 `git pull origin <target_branch>`
   - 현재 branch를 유지한 채 `git pull origin <target_branch>`
   - skip
6. `switch`를 골랐는데 branch 전환이 로컬 변경 때문에 막히면, 바로 skip하지 않고 현재 branch에서 `git pull origin <target_branch>`를 한 번 더 시도
7. `switch`를 골랐는데 branch 전환이 `.git/index.lock` 때문에 막히면, stale lock 파일을 삭제한 뒤 같은 branch 전환을 한 번 더 시도
8. 비대화형 실행에서는 `--branch-mismatch-mode switch|pull-current|skip`로 미리 지정 가능
9. `--branch-mismatch-mode pull-current`와 `--develop-sync-mode merge|rebase|skip`를 함께 쓰면, 대상 branch가 `develop`일 때는 현재 branch 위로 최신 `develop`을 `merge` 또는 `rebase` 방식으로 가져올 수 있음
10. 로컬 변경 사항이 있어도 `checkout` 또는 `pull`이 실제로 가능한 경우 그대로 진행
11. 아래 상황처럼 Git이 로컬 변경 사항 때문에 진행을 거부할 때만 skip
   - branch 전환 시 덮어쓰기 위험이 있는 경우
   - pull/merge 시 덮어쓰기 위험이 있는 경우

repo별 custom clone URL이 설정되어 있으면 fetch 전에 `origin` URL도 같이 맞춰줍니다.

`--repo`와 `--exclude-repo`를 함께 쓰면, 먼저 `--repo`로 대상을 좁힌 뒤 그 안에서 `--exclude-repo`를 제외합니다.
`--skip-repo`는 `--exclude-repo`의 별칭으로 같이 사용할 수 있습니다.

## 현재 config 기준 예시

blackbox workspace 업데이트:

```bash
export ROS_WS=/home/aeirobot/ROS2/blackbox_ws
./update_repos.sh --config blackbox
```

gripper workspace 업데이트:

```bash
./update_repos.sh --workspace /home/aeirobot/ROS2/gripper_ws --config gripper
```

특정 repo만 실행:

```bash
./update_repos.sh --workspace /home/aeirobot/ROS2/blackbox_ws --config blackbox --repo aeirobot_debug_tools
```

특정 repo 제외:

```bash
./update_repos.sh --workspace /home/aeirobot/ROS2/blackbox_ws --config blackbox --exclude-repo aeirobot_debug_tools
```

`file_path` 사용 예시:

```bash
./update_repos.sh --config my_direct_path_config --repo alice_main
```
