# brt — русский gettext-транслит для TTY

`brt` (best Russian translit) добавляет отдельную локаль gettext `ru@brt` с пользовательской схемой транслитерации. Установщик не переустанавливает программы и не меняет штатные русские каталоги.

## Установка

Нужны Bash 4+, GNU gettext (`msgunfmt`, `msgfmt`), Python 3, GNU coreutils и GNU findutils. Пакеты для популярных дистрибутивов:

### Arch Linux

```sh
sudo pacman -S --needed gettext python
```

### Debian и Ubuntu

```sh
sudo apt update
sudo apt install gettext python3
```

### Fedora

```sh
sudo dnf install gettext python3
```

### openSUSE Leap и Tumbleweed

```sh
sudo zypper install gettext-tools python3
```

Затем получи файлы репозитория. Для публичного репозитория используй HTTPS:

```sh
git clone https://github.com/wranok/brt.git
cd brt
```

Если репозиторий закрытый или на компьютере настроен SSH-ключ GitHub:

```sh
git clone git@github.com:wranok/brt.git
cd brt
```

Установи brt:

```sh
sudo bash ./install-ru-brt.sh install
```

Выйди из виртуальной консоли и войди снова. Установщик собирает русские `.mo`-каталоги из `/usr/share/locale/ru/LC_MESSAGES` и вариантов `ru_*`/`ru.*`, переводит строки `msgstr` по схеме brt и сохраняет их в `/usr/share/locale/ru@brt/`.

## Где работает

Транслит включается только в виртуальных консолях Linux вида `/dev/tty2`. Графические терминалы на `/dev/pts/N` сохраняют обычную кириллицу. Если `LC_ALL` в виртуальной консоли задан как `C` или его варианты UTF-8, установщик снимает это значение, чтобы gettext выбрал русские сообщения.

Схема применяется к программам с GNU gettext и установленными русскими каталогами, например к `nmtui` при наличии русского каталога NetworkManager. Программы со встроенными строками, другим механизмом локализации или каталогами вне `/usr/share/locale` этим способом не меняются.

## Схема brt

| Русская буква | Латиница | Русская буква | Латиница | Русская буква | Латиница |
|---|---|---|---|---|---|
| а | a | б | b | в | w |
| г | g | д | d | е | e |
| ё | e | ж | zz | з | z |
| и | i | й | j | к | k |
| л | l | м | m | н | n |
| о | o | п | p | р | r |
| с | s | т | t | у | u |
| ф | f | х | x | ц | c |
| ч | cc | ш | ss | щ | scc |
| ъ | h | ь | h | ы | y |
| э | ee | ю | iu | я | ia |

Для заглавной русской буквы заглавными становятся все латинские символы соответствия: `Ж → ZZ`, `Ч → CC`, `Щ → SCC`.

## Обновление каталогов

На Arch Linux устанавливается pacman hook, который пересобирает brt-каталоги после обновления пакетов с русскими locale-файлами.

На Debian, Ubuntu, Fedora, openSUSE и других дистрибутивах запускай пересборку вручную после установки или обновления программ:

```sh
sudo /usr/local/libexec/ru-brt --rebuild
```

## Удаление

```sh
sudo /usr/local/libexec/ru-brt uninstall
```

Установщик удаляет только файлы, которые сам создал и которые не были изменены вручную.
