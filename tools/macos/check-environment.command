#!/bin/bash -p
set +x

interactive=1
apply=0
workspace=''
log_open=0
probe=''
for argument in "$@"; do
    [[ $argument == --non-interactive ]] && interactive=0
done

finish() {
    local result=$?
    if [[ -n $probe ]] && ! /bin/rm -f -- "$probe" 2>/dev/null; then
        printf '%s\n' '실패 — 쓰기 확인용 임시 파일을 지우지 못했습니다.' >&2
        result=1
    fi
    if (( interactive )) && [[ -t 0 && -t 1 ]]; then
        printf '\nEnter 키를 누르면 종료합니다. '
        IFS= read -r unused || :
    fi
    exit "$result"
}
trap finish EXIT

status() {
    printf '%s\n' "$1"
    if (( log_open )) && ! { printf '%s\n' "$1" >&3; } 2>/dev/null; then
        printf '%s\n' '실패 — 로그를 저장하지 못했습니다.' >&2
        exit 1
    fi
}

fail() {
    status "실패 — $2"
    exit "$1"
}

while (( $# )); do
    case $1 in
        --non-interactive) shift ;;
        --apply-identity) apply=1; shift ;;
        --workspace)
            [[ $# -ge 2 && -n $2 && $2 != --* && -z $workspace ]] ||
                fail 2 '--workspace 뒤에 작업 폴더 하나를 적으세요.'
            workspace=$2
            shift 2
            ;;
        *) fail 2 '사용법 — check-environment.command [--non-interactive] [--workspace 폴더] [--apply-identity]' ;;
    esac
done

[[ $(/usr/bin/uname -s) == Darwin ]] || fail 1 'macOS가 필요합니다.'
export LC_ALL=en_US.UTF-8

# Inspect each path component before normalizing dots so aliases cannot hide in ../.
physical_directory() {
    local remaining=$1 current=/ component
    [[ $remaining == /* ]] || remaining="$PWD/$remaining"
    [[ $remaining != *$'\n'* && $remaining != *$'\r'* ]] || return 1
    while [[ -n $remaining ]]; do
        component=$remaining
        if [[ $remaining == */* ]]; then
            component=${remaining%%/*}
            remaining=${remaining#*/}
        else
            remaining=''
        fi
        case $component in
            ''|.) continue ;;
            ..) current=${current%/*}; current=${current:-/} ;;
            *)
                current="${current%/}/$component"
                [[ -d $current && ! -L $current ]] || return 1
                ;;
        esac
    done
    (cd -P -- "$current" && pwd -P)
}

if [[ -z $workspace ]]; then
    script_path=${BASH_SOURCE[0]}
    [[ ! -L $script_path ]] || fail 1 '링크가 아닌 원래 실행 파일을 여세요.'
    script_directory=.
    [[ $script_path == */* ]] && script_directory=${script_path%/*}
    workspace="$script_directory/../.."
fi
root=$(physical_directory "$workspace" 2>/dev/null) ||
    fail 1 '작업 폴더를 찾을 수 없습니다. 심볼릭 링크를 거치지 않는 실제 폴더를 지정하세요.'

for key in GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_IMPLICIT_WORK_TREE GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_CONFIG \
    GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
    "${!GIT_TRACE@}"; do
    [[ ! ${!key+x} ]] ||
        fail 1 'Git 경로나 설정을 바꾸는 환경 변수가 있습니다. 기본 환경에서 다시 실행하세요.'
done
# Keep Git from opening configured trace files while verifying a workspace.
export GIT_TRACE2=0 GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0
git_path=$(type -P git) || fail 1 'Git을 찾을 수 없습니다. 승인된 Git 설치를 확인하세요.'
if [[ $git_path -ef /usr/bin/git ]]; then
    # Use the selected developer tool directly. The Apple shim can offer installation.
    developer_path=$(/usr/bin/xcode-select -p 2>/dev/null) || developer_path=''
    [[ -n $developer_path && -x $developer_path/usr/bin/git &&
        ! $developer_path/usr/bin/git -ef /usr/bin/git ]] ||
        fail 1 '사용할 Git이 없습니다. 개발자 도구나 Git 설치 방법을 담당자와 확인하세요.'
    git_path="$developer_path/usr/bin/git"
fi
git_local() {
    "$git_path" --no-pager -C "$root" "$@" 2>/dev/null
}
git_version=$(git_local --version) || fail 1 'Git을 실행할 수 없습니다.'
git_version_pattern='^git version ([0-9][0-9A-Za-z.-]+)( \([A-Za-z0-9 .-]+\))?$'
[[ $git_version =~ $git_version_pattern ]] || fail 1 'Git 버전을 확인할 수 없습니다.'
git_version=${BASH_REMATCH[1]}
metadata="$root/.git"
[[ -d $metadata && ! -L $metadata && ! -e $metadata/commondir && ! -L $metadata/commondir &&
    -f $metadata/config && ! -L $metadata/config ]] ||
    fail 1 '작업 폴더 안에 직접 설정 파일이 있는 독립 Git 저장소가 필요합니다.'
top=$(git_local rev-parse --show-toplevel) ||
    fail 1 '지정한 작업 폴더에서 Git 저장소를 찾을 수 없습니다.'
[[ $top == "$root" ]] || fail 1 '지정한 작업 폴더가 저장소의 최상위 폴더와 다릅니다.'
settings="$root/.user_info"
[[ ! -L $settings && ( ! -e $settings || -f $settings ) ]] ||
    fail 1 '.user_info는 이 폴더에 직접 저장한 일반 파일이어야 합니다.'

umask 077
log_dir="$root/logs"
[[ ! -L $log_dir && ( ! -e $log_dir || -d $log_dir ) ]] ||
    fail 1 'logs가 링크이거나 폴더가 아닙니다.'
/bin/mkdir -p -- "$log_dir" 2>/dev/null ||
    fail 1 'logs 폴더를 만들 수 없습니다.'
[[ $(physical_directory "$log_dir" 2>/dev/null) == "$log_dir" ]] ||
    fail 1 'logs 폴더의 실제 경로를 확인할 수 없습니다.'
log_id=$(/usr/bin/uuidgen 2>/dev/null) || fail 1 '새 로그 이름을 만들 수 없습니다.'
log_name="macos-check.$log_id"
# Create and hold the log in one redirection under the verified directory.
set -C
if ! { exec 3>"$log_dir/$log_name"; } 2>/dev/null; then
    fail 1 '새 로그를 만들 수 없습니다.'
fi
set +C
log_open=1
status "로그 — logs/$log_name"
mac_version=$(/usr/bin/sw_vers -productVersion 2>/dev/null) || mac_version=''
status "정상 — macOS ${mac_version:-버전 미확인}"
status "정상 — Git $git_version / 작업 폴더와 Git 루트 일치"
probe=$(/usr/bin/mktemp "$root/.macos-check-probe.XXXXXXXX" 2>/dev/null) ||
    fail 1 '작업 폴더에 쓰기 확인용 임시 파일을 만들 수 없습니다.'
if ! /bin/rm -- "$probe" 2>/dev/null; then
    fail 1 '쓰기 확인용 임시 파일을 지우지 못했습니다.'
fi
probe=''
status '정상 — 작업 폴더 쓰기 및 임시 파일 삭제'

architecture=$(/usr/bin/uname -m 2>/dev/null) && status "정보 — 아키텍처 $architecture"
groups=$(/usr/bin/id -Gn 2>/dev/null)
if [[ $? -ne 0 ]]; then
    status '정보 — 관리자 그룹 여부를 확인할 수 없습니다.'
elif [[ " $groups " == *' admin '* || $EUID == 0 ]]; then
    status '정보 — 관리자 계정입니다.'
else
    status '정보 — 일반 계정입니다.'
fi
gh_path=$(type -P gh)
gh_version_pattern='^gh version ([0-9][0-9A-Za-z.-]+)( |$)'
if [[ -z $gh_path ]]; then
    status '선택 — 현재 환경에서 gh를 찾을 수 없습니다. 로컬 작업은 계속할 수 있습니다.'
elif gh_version=$(GH_NO_UPDATE_NOTIFIER=1 GH_NO_EXTENSION_UPDATE_NOTIFIER=1 "$gh_path" --version 2>/dev/null) &&
    [[ $gh_version =~ $gh_version_pattern ]]; then
    status "선택 — gh ${BASH_REMATCH[1]}"
else
    status '선택 — gh 버전을 확인할 수 없습니다. 로컬 작업은 계속할 수 있습니다.'
fi
status '미확인 — GitHub 로그인은 공유할 때 각자의 계정으로 확인하세요.'
status 'NOT_CHECKED — 제품 런타임은 기술 선택 뒤 확인합니다.'

trim_value() {
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
}

valid_identity() {
    local key=$1 candidate=$2 LC_ALL=C
    local email_pattern="^[A-Za-z0-9.!#\$%&'*+/=?^_{|}~-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"
    [[ -n $candidate && $candidate != *[[:cntrl:]]* && $candidate != *$'\302'[$'\200'-$'\237']* ]] ||
        return 1
    if [[ $key == GIT_NAME ]]; then
        [[ $candidate != *'"'* && $candidate != *'<'* && $candidate != *'>'* && $candidate != *\\ ]]
    else
        [[ $candidate =~ $email_pattern ]]
    fi
}

valid_repository() {
    local LC_ALL=C pattern='^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
    [[ $1 =~ $pattern ]]
}

keys=(GIT_NAME GIT_EMAIL GIT_REPOSITORY)
settings_values=('' '' '')
seen=(0 0 0)
if [[ -f $settings ]]; then
    # A marker preserves final newlines. The byte comparison rejects bytes Bash
    # cannot store (such as NUL), as well as a file changed while it was read.
    settings_text=$(
        /usr/bin/iconv -f UTF-8 -t UTF-8 "$settings" || exit 1
        printf '\001'
    ) 2>/dev/null || fail 1 '.user_info를 읽을 수 없습니다. UTF-8 일반 텍스트로 저장하세요.'
    settings_text=${settings_text%$'\001'}
    printf '%s' "$settings_text" | /usr/bin/cmp -s - "$settings" ||
        fail 1 '.user_info에 올바르지 않은 바이트가 있거나 읽는 중 바뀌었습니다.'
    settings_text=${settings_text#$'\357\273\277'}
    line_number=0
    while IFS= read -r line || [[ -n $line ]]; do
        (( line_number += 1 ))
        [[ -n $line ]] || continue
        case $line in
            GIT_NAME=*) index=0 ;;
            GIT_EMAIL=*) index=1 ;;
            GIT_REPOSITORY=*) index=2 ;;
            *) fail 1 ".user_info의 $line_number 번째 줄에 예제의 키와 =를 사용하세요." ;;
        esac
        key=${keys[index]}
        (( ! seen[index] )) || fail 1 ".user_info에 $key 항목이 두 번 이상 있습니다."
        seen[index]=1
        value=${line#*=}
        [[ $value != *[[:cntrl:]]* ]] || fail 1 ".user_info의 $key 값에 제어 문자가 있습니다."
        trim_value
        if [[ $value == \"*\" && ${#value} -ge 2 ]]; then
            value=${value:1:${#value}-2}
            trim_value
        fi
        if [[ -n $value ]]; then
            if (( index == 2 )); then
                valid_repository "$value" || fail 1 'GIT_REPOSITORY에는 원시 GitHub HTTPS 저장소 주소를 쓰세요.'
            else
                valid_identity "$key" "$value" || fail 1 ".user_info의 $key 값 형식을 확인하세요."
            fi
        fi
        settings_values[index]=$value
    done < <(printf '%s' "${settings_text//$'\r\n'/$'\n'}")
fi
if [[ -n ${settings_values[2]} ]]; then
    status '선택 — 공유 주소 항목이 있습니다.'
else
    status '선택 — 공유 주소는 필요할 때만 기록하세요.'
fi

# Read only an explicit config key. An LF plus a sentinel preserves blank and
# duplicate values, so only a single well-formed value can be reused.
read_identity() {
    local key=$1 capture result original
    shift
    capture=$(git_local config "$@" || exit $?; printf '\001')
    result=$?
    value=''
    [[ $result == 1 && -z $capture ]] && return 1
    [[ $result == 0 ]] || return 2
    capture=${capture%$'\001'}
    [[ $capture == *$'\n' ]] || return 2
    value=${capture%$'\n'}
    original=$value
    trim_value
    [[ $value == "$original" ]] && valid_identity "$key" "$value" || return 2
}

commit_matches() {
    local expected_name=$1 expected_email=$2 role actual
    local pattern='^(.+) <([^<>]+)> -?[0-9]+ [+-][0-9]{4}$'
    local match=0
    for role in GIT_AUTHOR_IDENT GIT_COMMITTER_IDENT; do
        if ! actual=$(git_local var "$role") || ! [[ $actual =~ $pattern ]] ||
            [[ ${BASH_REMATCH[1]} != "$expected_name" || ${BASH_REMATCH[2]} != "$expected_email" ]]; then
            match=1
        fi
    done
    return "$match"
}

git_keys=(user.name user.email)
effective=('' '')
candidate=('' '')
pending=()
missing=()
conflicts=()
override=0
for index in 0 1; do
    key=${keys[index]}
    git_key=${git_keys[index]}
    if read_identity "$key" --get -- "$git_key"; then
        effective[index]=$value
    elif [[ $? != 1 ]]; then
        override=1
    fi
    if read_identity "$key" --local --no-includes --get-all -- "$git_key"; then
        candidate[index]=$value
        if [[ -n ${settings_values[index]} && ${settings_values[index]} != "$value" ]]; then
            conflicts+=("$key")
        fi
    elif [[ $? == 1 ]]; then
        pending+=("$index")
        candidate[index]=${settings_values[index]:-${effective[index]}}
        [[ -n ${candidate[index]} ]] || missing+=("$key")
    else
        fail 1 "저장소 로컬 $git_key 값이 비어 있거나 중복되었는지 확인하세요."
    fi
done
(( ${#conflicts[@]} == 0 )) ||
    fail 1 "로컬 Git 값과 설정 파일이 충돌합니다. 확인할 항목 — ${conflicts[*]}"

git_local config --name-only --get-regexp '^(author|committer)\.(name|email)$' >/dev/null
[[ $? == 1 ]] || override=1
for key in GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
    GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE; do
    [[ ! ${!key+x} ]] || override=1
done

identity_matches=0
if commit_matches "${effective[0]}" "${effective[1]}"; then
    if [[ ${effective[0]} == "${candidate[0]}" && ${effective[1]} == "${candidate[1]}" ]]; then
        identity_matches=1
    fi
elif [[ -n ${effective[0]} && -n ${effective[1]} ]]; then
    override=1
fi

if (( override )); then
    if (( apply )); then
        fail 3 '작성자·커미터 별도 설정이나 환경 변수가 있거나 확인할 수 없어 로컬 적용을 보류합니다.'
    fi
    status '커밋 신원 미확인 — 작성자·커미터 별도 설정이나 환경 변수를 확인하세요.'
fi

if (( apply && ${#pending[@]} )); then
    (( ${#missing[@]} == 0 )) ||
        fail 3 "로컬 설정을 적용하려면 .user_info에 입력하세요 — ${missing[*]}"
    git_local config --local --no-includes --name-only --get-regexp \
        '^(include\.|includeif\.|extensions\.worktreeconfig$)' >/dev/null
    [[ $? == 1 ]] || fail 3 '간접 Git 설정을 사용하는 저장소에는 자동으로 적용할 수 없습니다.'
    if ! GIT_AUTHOR_NAME="${candidate[0]}" GIT_AUTHOR_EMAIL="${candidate[1]}" \
        GIT_COMMITTER_NAME="${candidate[0]}" GIT_COMMITTER_EMAIL="${candidate[1]}" \
        commit_matches "${candidate[0]}" "${candidate[1]}"; then
        fail 3 'Git이 준비된 작성자·커미터 값을 그대로 사용할 수 없습니다. 이름과 이메일을 확인하세요.'
    fi
    for index in "${pending[@]}"; do
        key=${keys[index]}
        git_key=${git_keys[index]}
        read_identity "$key" --local --no-includes --get-all -- "$git_key"
        [[ $? == 1 ]] || fail 3 "적용 도중 $key 상태가 바뀌었습니다. 성공한 로컬 항목은 남습니다."
        git_local config --local --no-includes --add -- "$git_key" "${candidate[index]}" ||
            fail 3 "$key 적용이 실패했습니다. 앞서 성공한 로컬 항목은 남습니다."
        status "로컬 쓰기 완료 — $key"
        if ! read_identity "$key" --local --no-includes --get-all -- "$git_key" ||
            [[ $value != "${candidate[index]}" ]]; then
            fail 3 "$key 적용 결과를 확인하지 못했습니다. 로컬 상태를 확인하세요."
        fi
    done
    if commit_matches "${candidate[0]}" "${candidate[1]}"; then
        identity_matches=1
    else
        identity_matches=0
    fi
fi

if (( ${#missing[@]} )); then
    status "커밋 신원 준비 대기 — 필요한 값 — ${missing[*]}"
elif (( ! override )); then
    if (( identity_matches )); then
        status '확인 — 유효한 Git 작성자·커미터가 준비된 값과 일치합니다.'
    elif (( apply )); then
        fail 3 '유효한 작성자·커미터를 확인하지 못했습니다. 이미 적용된 로컬 항목은 남습니다.'
    else
        status '커밋 신원 미확인 — 유효한 작성자·커미터가 준비된 값과 일치하는지 확인하세요.'
    fi
fi
status '완료 — 환경 점검'
exit 0
