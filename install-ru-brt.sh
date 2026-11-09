#!/usr/bin/env bash
set -Eeuo pipefail

readonly LOCALE_ROOT="/usr/share/locale"
readonly LOCALE_BASE="$LOCALE_ROOT/ru@brt"
readonly LOCALE_MESSAGES="$LOCALE_BASE/LC_MESSAGES"
readonly MARKER="$LOCALE_BASE/.ru-brt-managed"
readonly CATALOG_MANIFEST="$LOCALE_BASE/.ru-brt-files"
readonly STATE_DIR="/var/lib/ru-brt"
readonly COMPONENT_MANIFEST="$STATE_DIR/components.sha256"
readonly HELPER="/usr/local/libexec/ru-brt"
readonly HOOK="/usr/share/libalpm/hooks/90-ru-brt.hook"
readonly PROFILE="/etc/profile.d/ru-brt.sh"
readonly FISH_CONFIG="/etc/fish/conf.d/ru-brt.fish"

BUILD_TMP=""
INSTALL_TMP=""
COMMITTING=0
INSTALL_ACTIVE=0
INSTALL_SUCCESS=0
UPDATE_ACTIVE=0
UPDATE_SUCCESS=0
PROFILE_STAGE=""
FISH_STAGE=""
declare -a INSTALL_CREATED=()
declare -a OLD_FILES=()
declare -a NEW_FILES=()

say() {
    printf '%s\n' "$*"
}

fail() {
    printf 'ru-brt: %s\n' "$*" >&2
    exit 1
}

require_root() {
    [[ $(id -u) -eq 0 ]] || fail "запусти команду через sudo."
}

require_linux() {
    [[ $(uname -s) == Linux ]] || fail "этот установщик предназначен для GNU/Linux."
}

require_tools() {
    local tool
    for tool in msgunfmt msgfmt python3 sha256sum awk install readlink; do
        command -v "$tool" >/dev/null 2>&1 || fail "не найдена команда $tool. Установи пакеты gettext и python."
    done
    [[ -d "$LOCALE_ROOT" ]] || fail "не найдена системная директория $LOCALE_ROOT."
}

hash_file() {
    sha256sum -- "$1" | awk '{print $1}'
}

tracked_hash() {
    awk -v target="$1" '$2 == target { print $1; count++ } END { if (count != 1) exit 1 }' "$COMPONENT_MANIFEST"
}

valid_catalog_name() {
    [[ "$1" == *.mo && "$1" != */* && "$1" != *$'\n'* ]]
}

check_managed_locale() {
    if [[ -e "$LOCALE_BASE" || -L "$LOCALE_BASE" ]]; then
        [[ -d "$LOCALE_BASE" && ! -L "$LOCALE_BASE" ]] || fail "$LOCALE_BASE не является обычной директорией."
        [[ -f "$MARKER" && ! -L "$MARKER" ]] || fail "$LOCALE_BASE уже существует и не создан ru-brt; установщик не будет его менять."
        [[ $(cat "$MARKER") == "managed by ru-brt" ]] || fail "маркер $MARKER имеет неизвестное содержимое."
        if [[ -e "$LOCALE_MESSAGES" || -L "$LOCALE_MESSAGES" ]]; then
            [[ -d "$LOCALE_MESSAGES" && ! -L "$LOCALE_MESSAGES" ]] || fail "$LOCALE_MESSAGES не является обычной директорией."
        fi
        [[ -f "$CATALOG_MANIFEST" && ! -L "$CATALOG_MANIFEST" ]] || fail "не найден список каталогов ru-brt; остановка для сохранения данных."
    fi
}

read_catalog_manifest() {
    OLD_FILES=()
    if [[ -f "$CATALOG_MANIFEST" ]]; then
        while IFS= read -r name || [[ -n "$name" ]]; do
            valid_catalog_name "$name" || fail "некорректная запись в $CATALOG_MANIFEST."
            OLD_FILES+=("$name")
        done < "$CATALOG_MANIFEST"
    fi
}

transliterate_po() {
    local input="$1"
    local output="$2"
    python3 - "$input" "$output" <<'PYTHON'
import re
import sys

source = {
    "а": "a", "б": "b", "в": "w", "г": "g", "д": "d", "е": "e",
    "ё": "e", "ж": "zz", "з": "z", "и": "i", "й": "j", "к": "k",
    "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
    "с": "s", "т": "t", "у": "u", "ф": "f", "х": "x", "ц": "c",
    "ч": "cc", "ш": "ss", "щ": "scc", "ъ": "h", "ь": "h", "ы": "y",
    "э": "ee", "ю": "iu", "я": "ia",
}
mapping = dict(source)
mapping.update({key.upper(): value.upper() for key, value in source.items()})
msgstr_line = re.compile(r"^\s*msgstr(?:\[\d+\])?(?:\s+|$)")
continuation_line = re.compile(r'^\s*"')

def transliterate_literal(line):
    result = []
    in_string = False
    escaped = False
    for char in line:
        if in_string:
            if escaped:
                result.append(char)
                escaped = False
            elif char == "\\":
                result.append(char)
                escaped = True
            elif char == '"':
                result.append(char)
                in_string = False
            else:
                result.append(mapping.get(char, char))
        else:
            result.append(char)
            if char == '"':
                in_string = True
    return "".join(result)

with open(sys.argv[1], "r", encoding="utf-8", errors="surrogateescape", newline="") as source_file:
    lines = source_file.readlines()

result = []
inside_msgstr = False
for line in lines:
    if msgstr_line.match(line):
        inside_msgstr = True
        result.append(transliterate_literal(line))
    elif inside_msgstr and continuation_line.match(line):
        result.append(transliterate_literal(line))
    else:
        inside_msgstr = False
        result.append(line)

with open(sys.argv[2], "w", encoding="utf-8", errors="surrogateescape", newline="") as output_file:
    output_file.writelines(result)
PYTHON
}

rollback_catalog_commit() {
    local name
    set +e
    for name in "${NEW_FILES[@]}" "${OLD_FILES[@]}"; do
        [[ -n "$name" ]] && rm -f -- "$LOCALE_MESSAGES/$name"
    done
    if [[ -d "$BUILD_TMP/old-catalogs" && -d "$LOCALE_MESSAGES" ]]; then
        for name in "${OLD_FILES[@]}"; do
            [[ -f "$BUILD_TMP/old-catalogs/$name" ]] && cp -p -- "$BUILD_TMP/old-catalogs/$name" "$LOCALE_MESSAGES/$name"
        done
    fi
    if [[ -f "$BUILD_TMP/old-manifest" ]]; then
        cp -p -- "$BUILD_TMP/old-manifest" "$CATALOG_MANIFEST"
    else
        rm -f -- "$CATALOG_MANIFEST"
    fi
    if [[ -f "$BUILD_TMP/old-marker" ]]; then
        cp -p -- "$BUILD_TMP/old-marker" "$MARKER"
    else
        rm -f -- "$MARKER"
    fi
    COMMITTING=0
}

on_exit() {
    local status="$?"
    if [[ "$COMMITTING" -eq 1 ]]; then
        rollback_catalog_commit
    fi
    if [[ "$INSTALL_ACTIVE" -eq 1 && "$INSTALL_SUCCESS" -eq 0 ]]; then
        local path
        for path in "${INSTALL_CREATED[@]}"; do
            rm -f -- "$path"
        done
        rm -f -- "$COMPONENT_MANIFEST"
        rmdir "$STATE_DIR" 2>/dev/null || true
    fi
    if [[ "$UPDATE_ACTIVE" -eq 1 && "$UPDATE_SUCCESS" -eq 0 ]]; then
        [[ -f "$INSTALL_TMP/old-profile" ]] && cp -p -- "$INSTALL_TMP/old-profile" "$PROFILE"
        [[ -f "$INSTALL_TMP/old-fish" ]] && cp -p -- "$INSTALL_TMP/old-fish" "$FISH_CONFIG"
        [[ -f "$INSTALL_TMP/old-components" ]] && cp -p -- "$INSTALL_TMP/old-components" "$COMPONENT_MANIFEST"
        [[ -n "$PROFILE_STAGE" ]] && rm -f -- "$PROFILE_STAGE"
        [[ -n "$FISH_STAGE" ]] && rm -f -- "$FISH_STAGE"
    fi
    [[ -n "$BUILD_TMP" ]] && rm -rf -- "$BUILD_TMP"
    [[ -n "$INSTALL_TMP" ]] && rm -rf -- "$INSTALL_TMP"
    return "$status"
}
trap on_exit EXIT

rebuild_catalogs() {
    local source_dir catalog domain raw_po translated_po selected_catalog name old
    local -a source_dirs=(
        "$LOCALE_ROOT/ru/LC_MESSAGES"
        "$LOCALE_ROOT"/ru_*/LC_MESSAGES
        "$LOCALE_ROOT"/ru.*/LC_MESSAGES
    )
    declare -A selected=()

    check_managed_locale
    read_catalog_manifest
    BUILD_TMP=$(mktemp -d "$LOCALE_ROOT/.ru-brt-build.XXXXXX")
    mkdir -p "$BUILD_TMP/LC_MESSAGES" "$BUILD_TMP/old-catalogs"

    for source_dir in "${source_dirs[@]}"; do
        [[ -d "$source_dir" ]] || continue
        for catalog in "$source_dir"/*.mo; do
            [[ -f "$catalog" ]] || continue
            domain="${catalog##*/}"
            domain="${domain%.mo}"
            if [[ -z "${selected[$domain]+present}" ]]; then
                selected["$domain"]="$catalog"
            fi
        done
    done
    [[ ${#selected[@]} -gt 0 ]] || fail "не найдены русские gettext-каталоги в $LOCALE_ROOT."

    mapfile -t domains < <(printf '%s\n' "${!selected[@]}" | LC_ALL=C sort)
    for domain in "${domains[@]}"; do
        selected_catalog="${selected[$domain]}"
        raw_po="$BUILD_TMP/$domain.raw.po"
        translated_po="$BUILD_TMP/$domain.brt.po"
        msgunfmt --force-po --no-wrap --output-file="$raw_po" "$selected_catalog"
        transliterate_po "$raw_po" "$translated_po"
        msgfmt --output-file="$BUILD_TMP/LC_MESSAGES/$domain.mo" "$translated_po"
    done

    mapfile -t NEW_FILES < <(find "$BUILD_TMP/LC_MESSAGES" -maxdepth 1 -type f -name '*.mo' -printf '%f\n' | LC_ALL=C sort)
    [[ ${#NEW_FILES[@]} -gt 0 ]] || fail "не удалось собрать ни одного каталога ru@brt."

    for name in "${NEW_FILES[@]}"; do
        valid_catalog_name "$name" || fail "некорректное имя каталога $name."
        if [[ -e "$LOCALE_MESSAGES/$name" || -L "$LOCALE_MESSAGES/$name" ]]; then
            old=0
            for domain in "${OLD_FILES[@]}"; do
                [[ "$domain" == "$name" ]] && old=1
            done
            [[ "$old" -eq 1 ]] || fail "каталог $LOCALE_MESSAGES/$name уже существует и не отслеживается ru-brt."
            [[ -f "$LOCALE_MESSAGES/$name" && ! -L "$LOCALE_MESSAGES/$name" ]] || fail "каталог $LOCALE_MESSAGES/$name не является обычным файлом."
        fi
    done

    if [[ -f "$CATALOG_MANIFEST" ]]; then
        cp -p -- "$CATALOG_MANIFEST" "$BUILD_TMP/old-manifest"
    fi
    if [[ -f "$MARKER" ]]; then
        cp -p -- "$MARKER" "$BUILD_TMP/old-marker"
    fi
    for name in "${OLD_FILES[@]}"; do
        if [[ -f "$LOCALE_MESSAGES/$name" ]]; then
            [[ ! -L "$LOCALE_MESSAGES/$name" ]] || fail "отслеживаемый каталог $LOCALE_MESSAGES/$name является ссылкой."
            cp -p -- "$LOCALE_MESSAGES/$name" "$BUILD_TMP/old-catalogs/$name"
        fi
    done

    mkdir -p "$LOCALE_MESSAGES"
    COMMITTING=1
    for name in "${NEW_FILES[@]}"; do
        install -m 0644 -- "$BUILD_TMP/LC_MESSAGES/$name" "$LOCALE_MESSAGES/$name"
    done
    for old in "${OLD_FILES[@]}"; do
        if [[ ! -f "$BUILD_TMP/LC_MESSAGES/$old" ]]; then
            rm -f -- "$LOCALE_MESSAGES/$old"
        fi
    done
    printf '%s\n' "${NEW_FILES[@]}" > "$BUILD_TMP/new-manifest"
    mv -f -- "$BUILD_TMP/new-manifest" "$CATALOG_MANIFEST"
    printf '%s\n' "managed by ru-brt" > "$BUILD_TMP/new-marker"
    mv -f -- "$BUILD_TMP/new-marker" "$MARKER"
    COMMITTING=0
    say "ru-brt: собраны каталоги: ${#NEW_FILES[@]}."
}

write_install_files() {
    cat > "$INSTALL_TMP/90-ru-brt.hook" <<'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Path
Target = usr/share/locale/ru/LC_MESSAGES/*.mo
Target = usr/share/locale/ru_RU/LC_MESSAGES/*.mo
Target = usr/share/locale/ru_RU.utf8/LC_MESSAGES/*.mo
Target = usr/share/locale/ru_RU.UTF-8/LC_MESSAGES/*.mo

[Action]
Description = Rebuild brt Russian gettext catalogs
When = PostTransaction
Exec = /usr/local/libexec/ru-brt --rebuild
Depends = gettext
Depends = python
HOOK

    cat > "$INSTALL_TMP/ru-brt.sh" <<'PROFILE'
case $- in
    *i*) ;;
    *) return ;;
esac

[ -t 0 ] && [ -t 1 ] || return

ru_brt_tty="$(tty 2>/dev/null || true)"
case "$ru_brt_tty" in
    /dev/tty[0-9]*) ;;
    *) unset ru_brt_tty; return ;;
esac
unset ru_brt_tty

ru_brt_lc_all="$(printenv LC_ALL 2>/dev/null || true)"
case "$ru_brt_lc_all" in
    C|C.UTF-8|C.utf8|C.UTF8)
        unset LC_ALL
        ;;
esac
unset ru_brt_lc_all
export LANGUAGE=ru@brt:ru
PROFILE

cat > "$INSTALL_TMP/ru-brt.fish" <<'FISH'
if status is-interactive; and test -t 0; and test -t 1
    set -l ru_brt_tty (tty 2>/dev/null)
    if string match -rq '^/dev/tty[0-9]+$' -- "$ru_brt_tty"
        switch $LC_ALL
            case C C.UTF-8 C.utf8 C.UTF8
                set -e LC_ALL
        end
        set -gx LANGUAGE ru@brt:ru
    end
end
FISH
}

install_overlay() {
    local path
    require_root
    require_linux
    require_tools
    check_managed_locale
    [[ ! -e "$HELPER" && ! -L "$HELPER" ]] || fail "$HELPER уже существует; сначала проверь его вручную."
    if command -v pacman >/dev/null 2>&1; then
        [[ ! -e "$HOOK" && ! -L "$HOOK" ]] || fail "$HOOK уже существует; установщик не будет его перезаписывать."
    fi
    [[ ! -e "$PROFILE" && ! -L "$PROFILE" ]] || fail "$PROFILE уже существует; установщик не будет его перезаписывать."
    [[ ! -e "$FISH_CONFIG" && ! -L "$FISH_CONFIG" ]] || fail "$FISH_CONFIG уже существует; установщик не будет его перезаписывать."
    [[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]] || fail "$STATE_DIR уже существует; установщик не будет его использовать."

    INSTALL_ACTIVE=1
    INSTALL_TMP=$(mktemp -d)
    write_install_files
    install -D -m 0755 -- "$(readlink -f -- "$0")" "$HELPER"
    INSTALL_CREATED+=("$HELPER")
    if command -v pacman >/dev/null 2>&1; then
        install -D -m 0644 -- "$INSTALL_TMP/90-ru-brt.hook" "$HOOK"
        INSTALL_CREATED+=("$HOOK")
    fi
    install -D -m 0644 -- "$INSTALL_TMP/ru-brt.sh" "$PROFILE"
    INSTALL_CREATED+=("$PROFILE")
    install -D -m 0644 -- "$INSTALL_TMP/ru-brt.fish" "$FISH_CONFIG"
    INSTALL_CREATED+=("$FISH_CONFIG")

    mkdir -p "$STATE_DIR"
    : > "$COMPONENT_MANIFEST"
    for path in "${INSTALL_CREATED[@]}"; do
        printf '%s %s\n' "$(hash_file "$path")" "$path" >> "$COMPONENT_MANIFEST"
    done

    rebuild_catalogs
    INSTALL_SUCCESS=1
    say "ru-brt установлен. Перезайди в TTY, чтобы применить LANGUAGE=ru@brt:ru."
    if command -v pacman >/dev/null 2>&1; then
        say "Для обновлений каталогов установлен pacman hook."
    else
        say "После обновления программ вручную запусти: sudo $HELPER --rebuild"
    fi
}

update_tty_scope() {
    local old_profile_hash old_fish_hash component_hash component_path new_manifest profile_hash fish_hash
    local profile_seen=0 fish_seen=0
    require_root
    require_linux
    [[ -f "$COMPONENT_MANIFEST" && ! -L "$COMPONENT_MANIFEST" ]] || fail "не найден список установленного ru-brt в $COMPONENT_MANIFEST."
    [[ -f "$PROFILE" && ! -L "$PROFILE" ]] || fail "$PROFILE отсутствует или является ссылкой."
    [[ -f "$FISH_CONFIG" && ! -L "$FISH_CONFIG" ]] || fail "$FISH_CONFIG отсутствует или является ссылкой."
    old_profile_hash="$(tracked_hash "$PROFILE")" || fail "в списке ru-brt нет ровно одной записи для $PROFILE."
    old_fish_hash="$(tracked_hash "$FISH_CONFIG")" || fail "в списке ru-brt нет ровно одной записи для $FISH_CONFIG."
    [[ "$(hash_file "$PROFILE")" == "$old_profile_hash" ]] || fail "$PROFILE изменён вручную; сохраню его без изменений."
    [[ "$(hash_file "$FISH_CONFIG")" == "$old_fish_hash" ]] || fail "$FISH_CONFIG изменён вручную; сохраню его без изменений."

    INSTALL_TMP=$(mktemp -d)
    write_install_files
    cp -p -- "$PROFILE" "$INSTALL_TMP/old-profile"
    cp -p -- "$FISH_CONFIG" "$INSTALL_TMP/old-fish"
    cp -p -- "$COMPONENT_MANIFEST" "$INSTALL_TMP/old-components"
    PROFILE_STAGE="$PROFILE.ru-brt-update.$$"
    FISH_STAGE="$FISH_CONFIG.ru-brt-update.$$"
    UPDATE_ACTIVE=1
    install -m 0644 -- "$INSTALL_TMP/ru-brt.sh" "$PROFILE_STAGE"
    install -m 0644 -- "$INSTALL_TMP/ru-brt.fish" "$FISH_STAGE"
    mv -f -- "$PROFILE_STAGE" "$PROFILE"
    mv -f -- "$FISH_STAGE" "$FISH_CONFIG"

    profile_hash="$(hash_file "$PROFILE")"
    fish_hash="$(hash_file "$FISH_CONFIG")"
    new_manifest="$INSTALL_TMP/components.sha256.new"
    while read -r component_hash component_path; do
        case "$component_path" in
            "$PROFILE")
                printf '%s %s\n' "$profile_hash" "$PROFILE" >> "$new_manifest"
                profile_seen=$((profile_seen + 1))
                ;;
            "$FISH_CONFIG")
                printf '%s %s\n' "$fish_hash" "$FISH_CONFIG" >> "$new_manifest"
                fish_seen=$((fish_seen + 1))
                ;;
            *)
                printf '%s %s\n' "$component_hash" "$component_path" >> "$new_manifest"
                ;;
        esac
    done < "$COMPONENT_MANIFEST"
    [[ "$profile_seen" -eq 1 && "$fish_seen" -eq 1 ]] || fail "неожиданный формат списка ru-brt; изменения будут отменены."
    mv -f -- "$new_manifest" "$COMPONENT_MANIFEST"
    UPDATE_SUCCESS=1
    say "ru-brt теперь включается только на виртуальной консоли /dev/ttyN. Перезапусти графический терминал и войди заново в TTY."
}

remove_catalogs() {
    local name
    if [[ ! -e "$LOCALE_BASE" && ! -L "$LOCALE_BASE" ]]; then
        return
    fi
    [[ -d "$LOCALE_BASE" && ! -L "$LOCALE_BASE" ]] || fail "$LOCALE_BASE не является обычной директорией."
    [[ -f "$MARKER" && ! -L "$MARKER" && $(cat "$MARKER") == "managed by ru-brt" ]] || fail "нет корректного маркера ru-brt; каталоги оставлены на месте."
    [[ -f "$CATALOG_MANIFEST" && ! -L "$CATALOG_MANIFEST" ]] || fail "нет списка каталогов ru-brt; каталоги оставлены на месте."
    while IFS= read -r name || [[ -n "$name" ]]; do
        valid_catalog_name "$name" || fail "некорректная запись в $CATALOG_MANIFEST."
        if [[ -e "$LOCALE_MESSAGES/$name" || -L "$LOCALE_MESSAGES/$name" ]]; then
            [[ -f "$LOCALE_MESSAGES/$name" && ! -L "$LOCALE_MESSAGES/$name" ]] || fail "$LOCALE_MESSAGES/$name не обычный файл; удаление остановлено."
            rm -f -- "$LOCALE_MESSAGES/$name"
        fi
    done < "$CATALOG_MANIFEST"
    rm -f -- "$CATALOG_MANIFEST" "$MARKER"
    rmdir "$LOCALE_MESSAGES" 2>/dev/null || true
    rmdir "$LOCALE_BASE" 2>/dev/null || true
}

uninstall_overlay() {
    local expected path actual
    local remaining="$STATE_DIR/components.sha256.remaining"
    require_root
    remove_catalogs
    if [[ -f "$COMPONENT_MANIFEST" && ! -L "$COMPONENT_MANIFEST" ]]; then
        : > "$remaining"
        while read -r expected path; do
            [[ -n "$expected" && -n "$path" ]] || continue
            case "$path" in
                "$HELPER"|"$HOOK"|"$PROFILE"|"$FISH_CONFIG") ;;
                *) say "ru-brt: пропущена неизвестная запись в $COMPONENT_MANIFEST."; continue ;;
            esac
            if [[ -e "$path" || -L "$path" ]]; then
                [[ -f "$path" && ! -L "$path" ]] || {
                    say "ru-brt: оставлен нестандартный файл $path."
                    printf '%s %s\n' "$expected" "$path" >> "$remaining"
                    continue
                }
                actual="$(hash_file "$path")"
                if [[ "$actual" == "$expected" ]]; then
                    rm -f -- "$path"
                else
                    say "ru-brt: файл изменён и оставлен: $path"
                    printf '%s %s\n' "$expected" "$path" >> "$remaining"
                fi
            fi
        done < "$COMPONENT_MANIFEST"
        if [[ -s "$remaining" ]]; then
            mv -f -- "$remaining" "$COMPONENT_MANIFEST"
        else
            rm -f -- "$remaining" "$COMPONENT_MANIFEST"
            rmdir "$STATE_DIR" 2>/dev/null || true
        fi
    fi
    say "ru-brt удалён. Файлы вне списка установщика сохранены."
}

main() {
    case "${1:-install}" in
        install)
            install_overlay
            ;;
        --rebuild)
            require_root
            require_linux
            require_tools
            rebuild_catalogs
            ;;
        uninstall)
            uninstall_overlay
            ;;
        update-tty-scope)
            update_tty_scope
            ;;
        *)
            printf 'Использование: sudo %s [install|uninstall|--rebuild|update-tty-scope]\n' "$0" >&2
            exit 2
            ;;
    esac
}

main "$@"
