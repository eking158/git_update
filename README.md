# git_update

`update_repos.sh`는 ROS workspace 안의 여러 git repo를 한 번에 관리하기 위한 스크립트입니다.

이 스크립트로 다음 작업을 할 수 있습니다.

- 없는 repo를 `<workspace>/src` 아래에 clone
- `file_path`가 있으면 해당 경로에 바로 clone
- 이미 있는 repo를 `fetch` + `pull`로 업데이트
- 로컬 변경 사항이 있는 repo는 자동으로 skip
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

`develop` sync 방식을 미리 지정:

```bash
./update_repos.sh --develop-sync-mode merge --config blackbox
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
2. uncommitted 또는 untracked 변경 사항이 있으면 skip
3. repo가 있고 깨끗한 상태라면
   - `git fetch --prune origin`
   - 원격에 pull 대상 branch가 있는지 확인
   - 현재 branch가 다르면 기본적으로 대상 branch로 전환
   - 로컬에 대상 branch가 없으면 원격 branch를 fetch한 뒤 local branch 생성 후 전환
   - 단, YAML의 branch가 `develop`이고 현재 branch가 다르면 현재 branch 위로 최신 `develop`을 가져옴
   - 이때 사용자는 `merge`, `rebase`, `skip` 중 하나를 선택할 수 있음
   - 비대화형 실행에서는 `--develop-sync-mode merge|rebase|skip`로 미리 지정 가능
   - 일반 branch 업데이트는 `git pull origin <branch>`를 사용

repo별 custom clone URL이 설정되어 있으면 fetch 전에 `origin` URL도 같이 맞춰줍니다.

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

`file_path` 사용 예시:

```bash
./update_repos.sh --config my_direct_path_config --repo alice_main
```
