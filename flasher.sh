#!/usr/bin/env bash
#
# VK Mini A113X: 
# Всё через вендорский протокол USB-прошивки, кабелем Type-C
#
#
set -euo pipefail

_self="${BASH_SOURCE[0]}"
case $_self in */*) _self="${_self%/*}" ;; *) _self=. ;; esac
HERE="$(cd -- "$_self" && pwd)"
unset _self
ROOT="$(cd -- "$HERE/../.." && pwd)"

UPDATE="${UPDATE:-}"
if [ -z "$UPDATE" ]; then
	for c in "$HERE/update" "$ROOT/tools/update"; do
		if [ -x "$c" ]; then UPDATE="$c"; break; fi
	done
fi
[ -n "$UPDATE" ] || UPDATE="$(command -v update 2>/dev/null || echo "$HERE/update")"

BOARDS="${BOARDS:-$HERE/flasher_stuff}"
FW_ALPINE="${FW_ALPINE:-$HERE/fw_alpine}"
IMAGE="${IMAGE:-$FW_ALPINE/Image}"
DTB="${DTB:-$FW_ALPINE/vk-mini-a113x.dtb}"
ROOTFS_UBI="${ROOTFS_UBI:-$FW_ALPINE/alpine3.24.1_rootfs.ubi}"

STOCK="${STOCK:-$HERE/stock}"

RECOVERY="${RECOVERY:-$HERE/Image-ramrootfs}"

IDENTIFY_TIMEOUT="${IDENTIFY_TIMEOUT:-120}"
IDENTIFY_POLL="${IDENTIFY_POLL:-0.1}"
SETTLE="${SETTLE:-5}"
BULKCMD_MAX=63
MWRITE_CHUNK="${MWRITE_CHUNK:-8388608}"
AML_SUDO="${SUDO-}"

KERNEL_ADDR=0x01080000
DTB_ADDR=0x01000000
ENV_ADDR=0x02000000
ENV_SIZE=0x10000
I2C_BUF=0x02040000

# Таблица загрузчика, не наша. Наши разделы лежат в её дырках, поэтому ядро и
# dtb пишутся по сырым смещениям через nand write, а не по имени.
VENDOR_PARTS="bootloader tpl misc boot_a boot_b system_a system_b data"
declare -A VPART_OFF=(
	[bootloader]=0x00000000 [tpl]=0x00800000 [misc]=0x01000000
	[boot_a]=0x01200000 [boot_b]=0x02200000
	[system_a]=0x03200000 [system_b]=0x07200000 [data]=0x0b200000
)
declare -A VPART_SIZE=(
	[bootloader]=0x00200000 [tpl]=0x00800000 [misc]=0x00200000
	[boot_a]=0x01000000 [boot_b]=0x01000000
	[system_a]=0x04000000 [system_b]=0x04000000 [data]=0x04e00000
)


KERNEL_OFF=0x01200000
DTB_OFF=0x02b00000
UBI_OFF=0x02c00000

FLASH_END=0x10000000


declare -A OURPART_OFF=([kernel]=$KERNEL_OFF [dtb]=$DTB_OFF [ubi]=$UBI_OFF)
declare -A OURPART_SIZE=(
	[kernel]=$((DTB_OFF - KERNEL_OFF))
	[dtb]=$((UBI_OFF - DTB_OFF))
	[ubi]=$((FLASH_END - UBI_OFF))
)
OUR_LOWER="bootloader tpl misc"


RSV_AREAS="bbt env keys dtbrsv ddr"
declare -A RSV_OFF=(
	[bbt]=$((0x00280000)) [env]=$((0x00300000)) [keys]=$((0x00400000))
	[dtbrsv]=$((0x00500000)) [ddr]=$((0x00580000))
)
declare -A RSV_SIZE=(
	[bbt]=$((0x00080000)) [env]=$((0x00100000)) [keys]=$((0x00100000))
	[dtbrsv]=$((0x00080000)) [ddr]=$((0x00040000))
)
declare -A RSV_WHAT=(
	[bbt]="таблица плохих блоков NAND"
	[env]="окружение U-Boot"
	[keys]="ключи, deviceid, model, serial этого аппарата"
	[dtbrsv]="вендорское дерево устройств"
	[ddr]="калибровка DDR"
)

# Страница с запасной областью, как их отдаёт read.raw и как нужно
# программатору. По 4096 страниц за раз, как делает вендорский инструмент.
RAW_PAGE=$((2048 + 64))
RAW_PAGES=4096
ERASE_BLOCK=$((0x20000))

dry_run=0
LEAVE=0
[ "${1:-}" = "--dry-run" ] && dry_run=1

BOARD="${BOARD:-}"
BOARDDIR=""
FW=""
ONLINE=0

# ------------------------------------------------------------------ обвязка

die() { echo "error: $*" >&2; exit 1; }

log() {
	[ -n "$BOARDDIR" ] || return 0
	printf '%s  %s\n' "$(date '+%F %T')" "$*" >> "$BOARDDIR/session.log"
}

# Коды возврата у вендорского тула мусорные: identify отвечает 9 на живом
# устройстве. Поэтому состояние читаем из текста вывода.
aml_raw() {
	local out rc=0
	if [ -n "$AML_SUDO" ]; then
		out="$("$AML_SUDO" "$UPDATE" "$@" 2>&1)" || rc=$?
	else
		out="$("$UPDATE" "$@" 2>&1)" || rc=$?
	fi
	printf '%s' "$out"
	return 0
}

aml_ok() {
	local out
	if [ "$dry_run" = 1 ]; then
		printf 'would run: update'; printf ' %q' "$@"; printf '\n'
		return 0
	fi
	out="$(aml_raw "$@")"
	log "update $* => ${out//$'\n'/ | }"
	printf '%s\n' "$out"
	! printf '%s' "$out" | grep -qiE 'err:|\[info\]failed'
}

# Каждый bulkcmd несёт лишнее первое слово: тул съедает ведущее ключевое слово
# носителя, а первая команда после identify всё равно теряет байты. "echo; "
# закрывает оба случая, отсюда и лимит 63, а не 64.
#
# Обрезание на 64 байтах молчаливое, а U-Boot отвечает на половину команды
# синтаксической ошибкой, которую никто не проверяет.
UB_PREFIX='echo; '
ub() { printf '%s%s' "$UB_PREFIX" "$1"; }

bulk() {
	local payload
	payload="$(ub "$1")"

	[ "${#payload}" -le "$BULKCMD_MAX" ] ||
		die "bulkcmd payload is ${#payload} bytes, the limit is $BULKCMD_MAX:
  $payload"

	aml_ok bulkcmd "$payload"
}

identified() { printf '%s' "$1" | grep -qi 'firmware version'; }

# -------------------------------------------------------------------- плата

# Загрузчик слушает около 450 мс после сброса, поэтому долбим identify, а не
# опрашиваем раз в секунду.
poll_for_device() {
	local flag rc

	flag="$(mktemp)"

	{
		deadline=$((SECONDS + IDENTIFY_TIMEOUT))
		tries=0

		while [ "$SECONDS" -lt "$deadline" ]; do
			if identified "$(aml_raw identify 7)"; then
				echo found > "$flag"
				printf 'XXX\n100\nПоймал за %d с.\nXXX\n' \
					$((IDENTIFY_TIMEOUT - (deadline - SECONDS)))
				break
			fi

			tries=$((tries + 1))

			# Ограничена частота картинки, а не опроса: dialog
			# десять раз в секунду мерцает.
			if [ $((tries % 5)) -eq 0 ]; then
				printf 'XXX\n%d\nВключите плату.\nЕсли уже включена, выдерните питание и вставьте обратно.\n\nосталось %d с, попыток %d\nXXX\n' \
					$(( (IDENTIFY_TIMEOUT - (deadline - SECONDS)) * 100 / IDENTIFY_TIMEOUT )) \
					$((deadline - SECONDS)) "$tries"
			fi

			sleep "$IDENTIFY_POLL"
		done
	} | dialog --title "Жду загрузчик" --gauge "\
Включите плату.

Загрузчик слушает хост около 450 мс после сброса, его нужно
поймать в этот момент." 12 72 0

	[ -s "$flag" ]
	rc=$?
	rm -f "$flag"
	return $rc
}

# Проверяем перед каждым действием: плата уходит из режима прошивки, как только
# что-нибудь загрузит.
ensure_online() {
	if [ "$ONLINE" = 1 ] && identified "$(aml_raw identify 7)"; then
		return 0
	fi
	ONLINE=0
	connect
}

connect() {
	if wait_for_device_quiet; then
		load_board
		return 0
	fi

	# Без правила udev тулу нужен root, и выглядит это как отсутствующая
	# плата. Только sudo -n: запрос пароля съел бы окно в 450 мс.
	if [ -z "$AML_SUDO" ] && sudo -n true 2>/dev/null; then
		AML_SUDO=sudo
		if wait_for_device_quiet; then
			load_board
			return 0
		fi
		AML_SUDO=
	fi

	if poll_for_device; then
		dialog --infobox "Поймал. Жду..." 5 48
		sleep "$SETTLE"
		load_board
		return 0
	fi

	dialog --title "Платы нет" --msgbox "\
За ${IDENTIFY_TIMEOUT} с никто не ответил.

  • подано ли на плату питание?
  • не загружена ли она сейчас в ОС?
  • без udev правила тулу нужен root: попробуйте SUDO=sudo $0" 12 70
	return 1
}

# Identify, пауза на устаканивание и запись в панель - десять секунд,
# в которые молчащий терминал неотличим от повисшего.
wait_for_device_quiet() {
	local out

	dialog --infobox "Ищу плату на USB..." 5 48
	out="$(aml_raw identify 7)"
	identified "$out" || return 1

	dialog --infobox "Плата найдена. Ждем..." 5 48
	sleep "$SETTLE"
	return 0
}

load_board() {
	local out

	out="$(aml_raw identify 7)"

	# Берём значение, выкидываем фразу. Оно одинаково у всех плат этой
	# модели, так что опознаёт прошивку и больше ничего.
	FW="$(printf '%s' "$out" | tr -d '\r' |
		sed -n 's/.*firmware version is *//Ip' | head -1)"
	[ -n "$FW" ] || FW="?"

	ONLINE=1
	prime_bulk
	panel_sign
	choose_board
	log "connected, fw=$FW, board=$BOARD"

	[ -f "$BOARDDIR/config" ] && . "$BOARDDIR/config"
}

# Первая команда bulkcmd после identify теряет свои первые четыре байта:
#
#     BULKcmd[ad store bootloader normal 0x200000]
#     Unknown command 'ad'
#
# Наши собственные команды выживают за счёт префикса "echo; ", но mread и mwrite
# строят свою bulkcmd внутри тула, куда префикс не вставить. Поэтому жертвуем
# одной ненужной командой.
prime_bulk() {
	[ "$dry_run" = 1 ] && return 0
	dialog --infobox "Бужу командный канал..." 5 48
	aml_raw bulkcmd "echo priming" >/dev/null 2>&1 || true
}

# Плата в режиме прошивки выглядит как выключенная.
panel_sign() {
	local reg

	[ "$dry_run" = 1 ] && return 0

	dialog --infobox "Зажигаю точки передней панели..." 5 48
	bulk "i2c dev 2" >/dev/null 2>&1 || return 0
	bulk "gpio set GPIOZ_4" >/dev/null 2>&1 || true

	for reg in "0x00 0x01" "0x01 0x00 0x24" "0x26 0x00 0x24" \
		   "0x35 0x01" "0x36 0x01" "0x10 0x60" "0x11 0x60" "0x25 0x00"; do
		bulk "i2c mw 0x3c $reg" >/dev/null 2>&1 || true
	done
}

# Шина читается без серийной консоли: i2c read кладёт байты в ОЗУ, а ОЗУ
# возвращается по USB. Заполняем 0xaa, иначе молчание неотличимо от 0x00.
i2c_peek() {
	local chip="$1" reg="$2" v

	bulk "mw.b $I2C_BUF 0xaa 0x10" >/dev/null 2>&1 || return 1
	bulk "i2c read $chip $reg 1 $I2C_BUF" >/dev/null 2>&1 || true
	aml_ok mread mem "$I2C_BUF" normal 0x10 "$BOARDDIR/.peek" >/dev/null 2>&1 || return 1

	v="$(od -An -tx1 -N1 "$BOARDDIR/.peek" 2>/dev/null | tr -d ' \n')"
	rm -f "$BOARDDIR/.peek"

	[ "$v" = "aa" ] && return 1
	printf '0x%s' "$v"
}


inventory() {
	local touch light panel aw amp="" ampbus="" bus notes=""

	bulk "i2c dev 2" >/dev/null 2>&1 || true

	touch="$(i2c_peek 0x15 0xff)" || touch=""
	light="$(i2c_peek 0x29 0x92)" || light=""
	panel="$(i2c_peek 0x3c 0x00)" || panel=""
	aw="$(i2c_peek 0x34 0x00)" || aw=""

	# 0x0c это общая громкость: обычные чтение и запись, без побочных
	# эффектов.
	bulk "gpio set GPIOA_18" >/dev/null 2>&1 || true
	for bus in 3 2 1 0; do
		bulk "i2c dev $bus" >/dev/null 2>&1 || continue
		amp="$(i2c_peek 0x2a 0x0c)" && { ampbus="$bus"; break; }
		amp=""
	done
	bulk "i2c dev 2" >/dev/null 2>&1 || true

	{
		printf 'тач        0x15  %s\n' \
			"$([ -n "$touch" ] && echo "отвечает, прошивка $touch" ||
			   echo "молчит")"
		printf 'датчик св. 0x29  %s\n' \
			"$([ -n "$light" ] && echo "отвечает, part id $light" ||
			   echo "молчит")"
		printf 'IS31FL3236 0x3c  %s\n' \
			"$([ -n "$panel" ] &&
			   echo "отвечает на чтение, а IS31FL3236 так не умеет" ||
			   echo "проверяется только глазами: две точки на панели")"
		printf 'AW21036    0x34  %s\n' \
			"$([ -n "$aw" ] && echo "ОТВЕЧАЕТ, на плате другая панель" ||
			   echo "молчит, значит панель не AW21036")"
		printf 'усилитель  0x2a  %s\n' \
			"$([ -n "$amp" ] &&
			   echo "ОТВЕЧАЕТ на шине $ampbus, громкость $amp" ||
			   echo "не проверить: он на i2c3, её загрузчик не видит")"
		printf 'микрофоны        не проверить: PDM, регистровой шины нет\n'
		printf 'кольцо           не проверить: SPI и только на запись\n'
		printf 'Wi-Fi            не проверить: SDIO и питание снято\n'
	} > "$BOARDDIR/inventory.txt"

	[ -n "$aw" ] && notes="$notes\n\nВНИМАНИЕ: ответил 0x34. Дерево устройств здесь описывает\nIS31FL3236 по 0x3c. На этой плате экран работать не будет."
	[ -n "$light" ] && [ "$light" != "0x71" ] &&
		notes="$notes\n\nВНИМАНИЕ: датчик света отдал part id $light вместо 0x71."
	[ -z "$touch" ] && notes="$notes\n\nВНИМАНИЕ: по 0x15 ответа нет, тач-контроллера не видно."

	printf '%s' "$notes"
}


choose_board() {
	local known=() d n

	[ -n "$BOARD" ] && [ -d "$BOARDS/$BOARD" ] && { set_board "$BOARD"; return 0; }

	for d in "$BOARDS"/*/; do
		[ -d "$d" ] || continue
		n="$(basename "$d")"
		known+=("$n" "$(board_summary "$n")")
	done

	if [ ${#known[@]} -eq 0 ]; then
		n=$(dialog --no-cancel --inputbox "\
Плат на учёте ещё нет. Как назовём эту?

Имя нужно только чтобы различать платы на этом компьютере. Саму плату
спросить нельзя, так что имя ничем не проверяется." 12 74 "board-1" \
			3>&1 1>&2 2>&3) || n="board-1"
		set_board "${n:-board-1}"
		return 0
	fi

	if [ ${#known[@]} -eq 2 ]; then
		set_board "${known[0]}"
		return 0
	fi

	n=$(dialog --no-cancel --menu "\
Какая это плата?

По USB она себя не называет." 16 70 6 \
		"${known[@]}" "+" "плата не из списка" 3>&1 1>&2 2>&3) || n="${known[0]}"

	if [ "$n" = "+" ]; then
		n=$(dialog --no-cancel --inputbox "Имя новой платы:" 9 50 \
			"board-$(( ${#known[@]} / 2 + 1 ))" 3>&1 1>&2 2>&3)
	fi

	set_board "${n:-${known[0]}}"
}

set_board() {
	BOARD="$1"
	BOARDDIR="$BOARDS/$BOARD"
	mkdir -p "$BOARDDIR/dump"

	# Бэкапы до разделения лежали в dump/, фолбек.
	STOCK_DUMP="$BOARDDIR/dump/stock"
	[ -n "$(ls -A "$STOCK_DUMP" 2>/dev/null)" ] ||
		[ -z "$(ls -A "$BOARDDIR/dump" 2>/dev/null)" ] ||
		STOCK_DUMP="$BOARDDIR/dump"
}

board_summary() {
	local d="$BOARDS/$1"
	printf '%s' \
		"$([ -n "$(ls -A "$d/dump" 2>/dev/null)" ] && echo "бэкап есть" || echo "бэкапа нет")"
}


# ------------------------------------------------------------------- пункты

item_backup() {
	local part size out got total=0 want=0 report="" found=0 missing verdict notes
	local kind dir picked picked_rsv
	local -a opts

	ensure_online || return


	dialog --infobox "Читаю окружение платы..." 5 40
	detect_kind

	kind=$(dialog --title "Что на плате" --default-item "$DETECTED_KIND" --menu "\
Что сейчас прошито?

Судя по окружению, это $DETECTED_WHAT. Если это не так, выберите
другое." 13 70 2 \
		stock  "стоковые разделы, читаются по именам" \
		alpine "альпайн, kernel dtb ubi по смещениям" \
		3>&1 1>&2 2>&3) || return

	dir="$BOARDDIR/dump/$kind"
	mkdir -p "$dir"

	if [ "$kind" = alpine ]; then
		backup_ours "$dir"
		return
	fi

	stock_map_screen
	stock_what_screen
	rsv_what_screen

	opts=()
	for part in $VENDOR_PARTS; do
		opts+=("$part" "$(printf '%8s МиБ' $((VPART_SIZE[$part] / 1048576)))" on)
	done
	picked=$(dialog --title "Что снимать" --checklist "\
Пробелом снимается галка, Enter подтверждает." 18 60 9 \
		"${opts[@]}" 3>&1 1>&2 2>&3) || return

	opts=()
	for part in $RSV_AREAS; do
		opts+=("$part" "${RSV_WHAT[$part]}" on)
	done
	picked_rsv=$(dialog --title "Что снимать из AML reserved" --checklist "\
Читается по адресам: имён у этих областей нет." 15 74 6 \
		"${opts[@]}" 3>&1 1>&2 2>&3) || return

	dialog --title "Прежде чем начать" --msgbox "\
Если колонка не сброшена к заводским настройкам -
в data останутся токены от VK аккаунта, координаты места где она
стояла, и пароль от сети Wi-Fi. Такой бэкап нельзя никому передавать.

Сбросить в дефолт: включить, как кольцо загорится белым - зажать
+ и - до сигнала." 15 74

	for part in $picked; do
		want=$((want + 1))
		size="$(readable_size "$part")"
		out="$dir/$part.bin"

		dialog --infobox "Читаю $part ($(( $((size)) / 1048576 )) МиБ)..." 5 44
		aml_ok mread store "$part" normal "$size" "$out" >/dev/null || true

		# Судим по файлу: раздел с плохими блоками короче, поэтому
		# чтение заканчивается ошибкой после последнего исправного
		# блока, а всё до него уже записано.
		got=$( [ -f "$out" ] && stat -Lc%s "$out" || echo 0 )
		if [ "$got" -eq 0 ]; then
			report="$report$(printf '%-11s %9s' "$part" "ОШИБКА")\n"
			continue
		fi
		total=$((total + 1))

		missing=$(( ($((VPART_SIZE[$part])) - got) / ERASE_BLOCK ))
		found=$((found + missing))

		report="$report$(printf '%-11s %8s КиБ' "$part" $((got / 1024)))"
		[ "$missing" -gt 0 ] &&
			report="$report$(printf '   плохих блоков: %d' "$missing")"
		report="$report\n"
	done

	for part in $picked_rsv; do
		want=$((want + 1))
		read_big_from_flash "${RSV_OFF[$part]}" "${RSV_SIZE[$part]}" \
			"$dir/rsv-$part.bin" "$part" || continue
		total=$((total + 1))
		report="$report$(printf '%-11s %8s КиБ' "$part" \
			$(( $(stat -Lc%s "$dir/rsv-$part.bin") / 1024 )))\n"
	done

	item_save_env

	if [ "$total" -lt "$want" ]; then
		verdict="Часть разделов не прочиталась, поэтому счёт неполный.
Сначала нужно разобраться с ними."
	elif [ "$found" -eq 0 ]; then
		verdict="Плохих блоков нет ни в одном разделе."
	else
		verdict="Всего плохих блоков: $found.
Адреса знать не нужно. Здесь это просто отметка о состоянии NAND."
	fi

	dialog --title "Бэкап" --msgbox "\
Прочитано разделов: $total из $want, в $dir/

$report
$verdict" 20 76

	if dialog --title "Полный дамп" --yesno "\
Снять ещё и полный дамп NAND одним файлом для программатора?

Это другой формат: страницы вместе с запасной областью, 2048+64
байта, битые блоки на своих физических местах.

Но при наличии плохих блоков на этой или на целевой микросхеме
- ничего не гарантируется." 16 72; then
		full_raw_dump "$dir/nand-full.raw.bin" &&
			dialog --msgbox "Полный дамп: $dir/nand-full.raw.bin" 7 66
	fi

}

restore_ours() {
	local dir="$BOARDDIR/dump/alpine" part opts=() write done_n=0 fail=""

	[ -n "$(ls -A "$dir" 2>/dev/null)" ] || {
		dialog --msgbox "\
Бэкапа альпайна нет.

Снимите его пунктом 0." 9 60
		return
	}

	for part in kernel dtb ubi; do
		[ -s "$dir/$part.bin" ] && opts+=("$part" "$(printf '%s МиБ' \
			$(( $(stat -Lc%s "$dir/$part.bin") / 1048576 )))" on)
	done

	[ "${#opts[@]}" -gt 0 ] || {
		dialog --msgbox "В $dir нет ни одного пригодного файла." 7 60
		return
	}

	write=$(dialog --title "Что вернуть" --checklist "\
Из $dir" 13 66 4 "${opts[@]}" 3>&1 1>&2 2>&3) || return
	[ -n "$write" ] || return

	ensure_online || return

	for part in $write; do
		bulk "nand erase ${OURPART_OFF[$part]} $(printf 0x%x \
			"$(( ($(stat -Lc%s "$dir/$part.bin") + ERASE_BLOCK - 1) \
			     / ERASE_BLOCK * ERASE_BLOCK ))")" >/dev/null || true
		if write_big_to_flash "$dir/$part.bin" "$KERNEL_ADDR" \
				      "${OURPART_OFF[$part]}" "$part"; then
			done_n=$((done_n + 1))
		else
			fail="$fail $part"
		fi
	done

	dialog --title "Готово" --msgbox "\
Записано областей: $done_n.${fail:+
Не легло:$fail}

Окружение не трогалось: если плата уже грузила альпайн, то
bootcmd на месте. Если нет, прошейте пунктом 3." 12 70
}

# Что говорит окружение о прошитом.
#
# Альпайн оставляет bootcmd "run ka kb kc kd".
# Это только подсказка: оборванная прошивка оставляет одно состояние на
# флеше и другое в окружении. Пишем в глобальную переменную: capture_env говорит
# с платой, и внутри подстановки команды любой нарисованный им диалог попал бы в
# захваченный текст.
DETECTED_KIND=stock
DETECTED_WHAT="сток"

detect_kind() {
	local f="$BOARDDIR/.env-probe"

	DETECTED_KIND=stock
	DETECTED_WHAT="сток"

	capture_env "$f"
	if grep -q '^bootcmd=run ka kb kc kd' "$f" 2>/dev/null; then
		DETECTED_KIND=alpine
		DETECTED_WHAT="альпайн"
	fi
	rm -f "$f"
}


stock_map_screen() {
	dialog --title "Разметка стока" --msgbox "\
0x00000000 - 0x00200000   bootloader      2 МиБ
0x00200000 - 0x00800000   AML reserved    6 МиБ
     0x00280000 - 0x00300000    BBT
     0x00300000 - 0x00400000    environment
     0x00400000 - 0x00500000    keys
     0x00500000 - 0x00580000    DTB reserve
     0x00580000 - 0x005c0000    DDR data
0x00800000 - 0x01000000   tpl             8 МиБ
0x01000000 - 0x01200000   misc            2 МиБ
0x01200000 - 0x02200000   boot_a         16 МиБ
0x02200000 - 0x03200000   boot_b         16 МиБ
0x03200000 - 0x07200000   system_a       64 МиБ
0x07200000 - 0x0b200000   system_b       64 МиБ
0x0b200000 - 0x10000000   data           78 МиБ" 22 66
}

stock_what_screen() {
	dialog --title "Что за что отвечает" --msgbox "\
bootloader     ранний старт
AML reserved   плато- и девайсо-зависимая часть, подробнее дальше
tpl            второй образ загрузчика
misc           флаг причины перезагрузки, для бэкапа не обязателен
boot_a boot_b  ядра, основное и запасное
system_a       корневые системы, основная и запасная
system_b
data           пользовательские данные" 16 70
}

rsv_what_screen() {
	dialog --title "Что внутри AML reserved" --msgbox "\
BBT           таблица плохих блоков именно этой NAND
environment   U-Boot envs
keys          ключи, deviceid, model и serial этого аппарата.
              MAC-адресов нет, они прожжены в efuse
DTB reserve   вендорское дерево устройств
DDR data      калибровка памяти. На этой плате её нет,
              загрузчик сообщает NO nddr exist, так что файл
              выйдет пустым

" 20 70
}



item_inventory() {
	local notes

	ensure_online || return

	dialog --infobox "Спрашиваю шину i2c, что распаяно..." 5 48
	notes="$(inventory)"

	panel_sign

	dialog --title "Что отвечает на шине" --msgbox "\
$(cat "$BOARDDIR/inventory.txt")$notes" 20 76
}


backup_ours() {
	local dir="$1" part size out got report=""

	for part in $OUR_LOWER; do
		size="$(readable_size "$part")"
		out="$dir/$part.bin"
		dialog --infobox "Читаю $part ($(( $((size)) / 1048576 )) МиБ)..." 5 44
		aml_ok mread store "$part" normal "$size" "$out" >/dev/null || true
		got=$( [ -f "$out" ] && stat -Lc%s "$out" || echo 0 )
		report="$report$(printf '%-11s %8s КиБ\n' "$part" $((got / 1024)))"
	done

	for part in kernel dtb ubi; do
		read_big_from_flash "${OURPART_OFF[$part]}" "${OURPART_SIZE[$part]}" \
			"$dir/$part.bin" "$part" || return 1
		report="$report$(printf '%-11s %8s КиБ\n' "$part" \
			$(( $(stat -Lc%s "$dir/$part.bin") / 1024 )))"
	done

	item_save_env

	dialog --title "Бэкап альпайна" --msgbox "\
Снято в $dir/

$report
" 18 76
	return 0
}

# Логическое пространство: раздел короче на один стёртый блок за каждый плохой,
# поэтому запрос номинального размера кончается на
#
#     Fail in find phy addr by logic off (0x4dc0000)
#
# и это нормально: всё до этого места уже записано, а короткий файл и есть
# измерение.
readable_size() {
	local part="$1"

	printf '0x%x' $((VPART_SIZE[$part]))
}

capture_env() {
	local out="$1"

	# Единственный способ получить текст: ответы bulkcmd уходят в UART, а
	# env export кладёт окружение в ОЗУ, и ОЗУ возвращается по USB.
	#
	# Сначала обнуляем площадку, иначе вместе с текстом приедет стена 0x55,
	# которую оставляет тест памяти в BL2.
	bulk "mw.b $ENV_ADDR 0 $ENV_SIZE" >/dev/null || true
	bulk "env export -t $ENV_ADDR" >/dev/null || true
	aml_ok mread mem "$ENV_ADDR" normal "$ENV_SIZE" "$out" >/dev/null || true

	# Два реза: по NUL, который гарантирован обнулением, и по первой строке,
	# не являющейся присваиванием.
	if [ -s "$out" ]; then
		sed -z 'q' < "$out" | awk '
			# Значение может занимать несколько строк, все кроме
			# последней кончаются обратной косой.
			!cont && !/^[A-Za-z_][A-Za-z0-9_.-]*=/ { exit }
			{ print; cont = /\\$/ }' \
			> "$out.clean"
		mv "$out.clean" "$out"
	fi

}

# И бэкапу, и прошивке нужно окружение на диске рядом с дампом, чтобы было с чем
# сравнить то, что на плате.
item_save_env() {
	ensure_online || return

	capture_env "$BOARDDIR/env.txt"
}

# Никуда не пишем
item_show_env() {
	local tmp

	ensure_online || return

	tmp="$(mktemp)"
	dialog --infobox "Читаю окружение платы..." 5 40
	capture_env "$tmp"
	dialog --title "Окружение платы" --textbox "$tmp" 25 78
	rm -f "$tmp"
}







# Стирание обязательно
write_to_flash() {
	local file="$1" ram="$2" off="$3" len="$4" what="$5"

	aml_ok mwrite "$file" mem "$ram" normal >/dev/null || {
		dialog --msgbox "Не удалось отправить в память: $what." 7 50
		return 1
	}

	bulk "nand write $ram $off $len" >/dev/null || {
		dialog --msgbox "Не удалось записать: $what." 7 50
		return 1
	}

	log "wrote $what: $file -> $off, $len"
	return 0
}

# Длинные значения приходится собирать по кускам: нагрузка bulkcmd жёстко
# ограничена 64 байтами, а обрезанную строку U-Boot считает синтаксической
# ошибкой.
set_long_var() {
	local var="$1" value="$2" acc="" word prefix

	# Первая команда присваивает, остальные дописывают. "setenv $var" без
	# значения - удаление, и оно возвращает ошибку, когда
	# удалять нечего.
	prefix="setenv $var "

	for word in $value; do
		if [ -n "$acc" ] &&
		   [ $((${#UB_PREFIX} + ${#prefix} + ${#acc} + 1 + ${#word})) -gt $BULKCMD_MAX ]; then
			bulk "$prefix$acc" >/dev/null || return 1
			acc="$word"
			prefix="setenv $var \${$var} "
		else
			[ $((${#UB_PREFIX} + ${#prefix} + ${#acc} + ${#word})) -le $BULKCMD_MAX ] ||
				die "single token too long for bulkcmd: $word"
			acc="${acc:+$acc }$word"
		fi
	done

	[ -n "$acc" ] && { bulk "$prefix$acc" >/dev/null || return 1; }
	return 0
}

# Linux пишет text_offset=0, а этот booti безусловно берёт адресом назначения
# SDRAM_BASE + text_offset. SDRAM_BASE здесь ноль, поэтому нетронутый Image
# переносится в задницу и booti говорит "Bad Linux ARM64 Image magic!". Поле
# правит скрипт сборки - тут просто защита от заливки
image_is_adapted() {
	python3 - "$1" <<-'EOF'
	import struct, sys

	h = open(sys.argv[1], 'rb').read(64)
	ok = (len(h) == 64 and h[56:60] == b'ARM\x64'
	      and struct.unpack('<Q', h[8:16])[0] != 0)
	sys.exit(0 if ok else 1)
	EOF
}

# Рутфс целиком в ОЗУ не положить: режем на куски по MWRITE_CHUNK
#
# require_files показывает нехватку заранее, а не на середине прошивки.
hsize() {
	local n="$1"

	if [ "$n" -ge 1048576 ]; then printf '%s МиБ' $((n / 1048576))
	elif [ "$n" -ge 1024 ]; then printf '%s КиБ' $((n / 1024))
	else printf '%s Б' "$n"; fi
}

# Длиннее бокса, поэтому оставляем первый каталог и имя файла, а середину
# выкидываем. Опознают файл именно концы.
shortpath() {
	local rel="$1"

	if [ "${#rel}" -le 44 ]; then
		printf '%s' "$rel"
	else
		printf '%s/.../%s' "${rel%%/*}" "${rel##*/}"
	fi
}

require_files() {
	local title="$1" path list="" all=0 n=0

	shift
	for path in "$@"; do
		n=$((n + 1))

		if [ -f "$path" ]; then
			list="$list
  есть  $(printf '%-49s %8s' \
		"$(shortpath "${path#$HERE/}")" \
		"$(hsize "$(stat -Lc%s "$path")")")"
		else
			list="$list
  НЕТ   $(shortpath "${path#$HERE/}")"
			all=1
		fi
	done

	dialog --title "$title" --msgbox "\
Всё берётся из папки скрипта:

  $HERE
$list" $((n + 8)) 76

	return $all
}

# Альпайн области лежат в дырках таблицы загрузчика, store их не назовёт.
read_big_from_flash() {
	local off="$1" size="$2" out="$3" what="$4"
	local ram="$KERNEL_ADDR" pos n tmp st

	tmp="$(mktemp)"
	st="$(mktemp)"
	pos=0
	: > "$out"

	{
		while [ "$pos" -lt "$size" ]; do
			n=$((size - pos))
			[ "$n" -gt "$MWRITE_CHUNK" ] && n=$MWRITE_CHUNK

			bulk "nand read $ram $(printf 0x%x $((off + pos))) $(printf 0x%x "$n")" >/dev/null ||
				{ echo "read $pos" > "$st"; break; }
			aml_ok mread mem "$ram" normal "$(printf 0x%x "$n")" "$tmp" >/dev/null ||
				{ echo "fetch $pos" > "$st"; break; }

			cat "$tmp" >> "$out"
			pos=$((pos + n))
			echo $((pos * 100 / size))
		done
	} | dialog --gauge "Читаю $what, $((size / 1048576)) МиБ" 8 62 0

	rm -f "$tmp"

	if [ -s "$st" ]; then
		dialog --msgbox "Оборвалось на $(cat "$st") байт: $what." 7 56
		rm -f "$st"
		return 1
	fi

	rm -f "$st"
	log "read $what: $off +$size -> $out"
	return 0
}

# Для программатора
full_raw_dump() {
	local out="$1" ram="$KERNEL_ADDR" off=0 tmp st chunk
	local step=$((RAW_PAGES * 2048))

	tmp="$(mktemp)"
	st="$(mktemp)"
	: > "$out"
	chunk=$((RAW_PAGES * RAW_PAGE))

	{
		while [ "$off" -lt "$((FLASH_END))" ]; do
			bulk "nand read.raw $ram $(printf 0x%x "$off") $(printf 0x%x "$RAW_PAGES")" >/dev/null ||
				{ echo "read $off" > "$st"; break; }
			aml_ok mread mem "$ram" normal "$(printf 0x%x "$chunk")" "$tmp" >/dev/null ||
				{ echo "fetch $off" > "$st"; break; }

			cat "$tmp" >> "$out"
			off=$((off + step))
			echo $((off * 100 / $((FLASH_END)) ))
		done
	} | dialog --gauge "Снимаю полный дамп с запасной областью" 8 62 0

	rm -f "$tmp"

	if [ -s "$st" ]; then
		dialog --msgbox "Оборвалось на $(cat "$st"): полный дамп." 7 56
		rm -f "$st"
		return 1
	fi

	rm -f "$st"
	log "raw dump -> $out, $(stat -Lc%s "$out") bytes"
	return 0
}

# Просто в ОЗУ, без записи во флеш. Аварийное ядро с рутфсом внутри крупнее
# того, что переживает одна mwrite, поэтому кусками по MWRITE_CHUNK подряд:
# образ должен лечь в память сплошняком, иначе booti найдёт не ядро.
mwrite_to_ram() {
	local file="$1" addr="$2" what="$3"
	local size pos n tmp st

	size=$(stat -Lc%s "$file")
	tmp="$(mktemp)"
	st="$(mktemp)"
	pos=0

	{
		while [ "$pos" -lt "$size" ]; do
			n=$((size - pos))
			[ "$n" -gt "$MWRITE_CHUNK" ] && n=$MWRITE_CHUNK

			dd if="$file" of="$tmp" bs=2048 conv=sync \
			   skip=$((pos / 2048)) count=$(( (n + 2047) / 2048 )) 2>/dev/null

			aml_ok mwrite "$tmp" mem \
			       "$(printf 0x%x $(( $((addr)) + pos )))" normal >/dev/null ||
				{ echo "$pos" > "$st"; break; }

			pos=$((pos + n))
			echo $((pos * 100 / size))
		done
	} | dialog --gauge "Отправляю $what, $((size / 1048576)) МиБ" 8 62 0

	rm -f "$tmp"

	if [ -s "$st" ]; then
		dialog --msgbox "Оборвалось на $(cat "$st") байт: $what." 7 56
		rm -f "$st"
		return 1
	fi

	rm -f "$st"
	log "to ram: $file -> $addr, $size bytes"
	return 0
}

write_big_to_flash() {
	local file="$1" ram="$2" off="$3" what="$4"
	local size pos n tmp st

	size=$(stat -Lc%s "$file")

	tmp="$(mktemp)"
	st="$(mktemp)"
	pos=0

	{
		while [ "$pos" -lt "$size" ]; do
			n=$((size - pos))
			[ "$n" -gt "$MWRITE_CHUNK" ] && n=$MWRITE_CHUNK
			n=$(( (n + 2047) / 2048 * 2048 ))

			# conv=sync добивает последний кусок нулями, поэтому
			# запрошенная длина равна отправленной.
			dd if="$file" of="$tmp" bs=2048 conv=sync \
			   skip=$((pos / 2048)) count=$((n / 2048)) 2>/dev/null

			aml_ok mwrite "$tmp" mem "$ram" normal >/dev/null ||
				{ echo "send $pos" > "$st"; break; }
			bulk "nand write $ram $(printf 0x%x $((off + pos))) $(printf 0x%x "$n")" >/dev/null ||
				{ echo "write $pos" > "$st"; break; }

			pos=$((pos + n))
			echo $((pos * 100 / size))
		done
	} | dialog --gauge "Пишу $what, $((size / 1048576)) МиБ" 8 62 0

	rm -f "$tmp"

	if [ -s "$st" ]; then
		dialog --msgbox "Оборвалось на $(cat "$st") байт: $what." 7 56
		rm -f "$st"
		return 1
	fi

	rm -f "$st"
	log "wrote $what: $file -> $off, $size bytes"
	return 0
}

item_flash() {
	local ksize dsize usize with_ubi=0 prompt erase_end erase_len wrong early
	local bootargs delay expected line

	require_files "Что нужно для прошивки" "$IMAGE" "$DTB" "$ROOTFS_UBI"

	[ -f "$IMAGE" ] && [ -f "$DTB" ] || {
		dialog --msgbox "Без ядра и дерева устройств прошивать нечего." 7 56
		return
	}

	ensure_online || return

	ksize=$(stat -Lc%s "$IMAGE")
	dsize=$(stat -Lc%s "$DTB")

	image_is_adapted "$IMAGE" || {
		dialog --msgbox "\
Заголовок ядра не подготовлен для этого загрузчика.

  $IMAGE

Вендорский booti перенёс бы его в физический ноль и не нашёл
ядра." 12 74
		return
	}

	if [ "$ksize" -gt $(( $((DTB_OFF)) - $((KERNEL_OFF)) )) ]; then
		dialog --msgbox "Ядро $((ksize / 1048576)) МиБ не влезает в раздел $(( ($((DTB_OFF)) - $((KERNEL_OFF))) / 1048576 )) МиБ." 7 66
		return
	fi
	if [ "$dsize" -gt $(( $((UBI_OFF)) - $((DTB_OFF)) )) ]; then
		dialog --msgbox "Дерево устройств не влезает в свой раздел." 7 52
		return
	fi

	prompt="Записать во флешь:

  ядро    $((ksize / 1048576)) МиБ  -> $KERNEL_OFF
  dtb     $((dsize / 1024)) КиБ  -> $DTB_OFF"

	if [ -f "$ROOTFS_UBI" ]; then
		with_ubi=1
		usize=$(stat -Lc%s "$ROOTFS_UBI")

		if [ "$usize" -gt $(( $((FLASH_END)) - $((UBI_OFF)) )) ]; then
			dialog --msgbox "Образ рутфса $((usize / 1048576)) МиБ не влезает в раздел $(( ($((FLASH_END)) - $((UBI_OFF))) / 1048576 )) МиБ." 7 70
			return
		fi
		prompt="$prompt
  рутфс   $((usize / 1048576)) МиБ  -> $UBI_OFF

Всё, что сейчас в этих трёх разделах, стирается."
	else
		prompt="$prompt

Образа рутфса нет:

  $ROOTFS_UBI

Пишутся только ядро, дерево устройств, и envs. Рутфс на плате
остаётся нетронутым - чекни модули ядра в ней после такого."
	fi

	dialog --yesno "$prompt

Служебные разделы не трогаются: ни загрузчик, ни reserved, ни tpl,
ни misc." 20 74 || return

	kread=$(printf 0x%08x $(( (ksize + ERASE_BLOCK - 1) / ERASE_BLOCK * ERASE_BLOCK )))
	dread=$(printf 0x%08x $(( (dsize + ERASE_BLOCK - 1) / ERASE_BLOCK * ERASE_BLOCK )))

	# Всё ниже KERNEL_OFF вендорское и не трогается. Без рутфса ерейс
	# останавливается на UBI_OFF.
	erase_end=$([ "$with_ubi" = 1 ] && echo "$FLASH_END" || echo "$UBI_OFF")
	erase_len=$(printf 0x%x $(( $((erase_end)) - $((KERNEL_OFF)) )))

	dialog --infobox "Стираю $(( ($((erase_end)) - $((KERNEL_OFF))) / 1048576 )) МиБ, от $KERNEL_OFF до $erase_end..." 5 66
	bulk "nand erase $KERNEL_OFF $erase_len" >/dev/null || {
		dialog --msgbox "Не удалось стереть область под запись." 7 52
		return
	}

	# Через ОЗУ. Адреса те же, по которым это
	# грузится при старте. Ядро идёт через кусочный писатель, ибо не сжато.
	if [ "$ksize" -gt "$MWRITE_CHUNK" ]; then
		write_big_to_flash "$IMAGE" "$KERNEL_ADDR" "$KERNEL_OFF" ядро || return
	else
		dialog --infobox "Отправляю ядро в память..." 5 40
		write_to_flash "$IMAGE" "$KERNEL_ADDR" "$KERNEL_OFF" "$kread" ядро || return
	fi

	dialog --infobox "Отправляю дерево устройств в память..." 5 44
	write_to_flash "$DTB" "$DTB_ADDR" "$DTB_OFF" "$dread" "дерево устройств" || return

	[ "$with_ubi" = 1 ] &&
		{ write_big_to_flash "$ROOTFS_UBI" "$KERNEL_ADDR" "$UBI_OFF" "рутфс" || return; }

	# Как плата загружается, в четырёх переменных.
	#
	# Разбито потому, что нагрузка bulkcmd упирается в 64 байта, а
	# обрезанную строку U-Boot читает как синтаксическую ошибку. И "setenv x
	# ${x} more" не умеет собрать значение с точкой с запятой: U-Boot
	# разворачивает переменную прямо при разборе.
	#
	# bootargs задаётся изнутри bootcmd, а не сохраняется: preboot кончается
	# на "run storeargs", который каждый раз пересобирает его заново.
	#
	#   ba командная строка ядра, ka кладёт её в bootargs, kb читает дерево,
	#   kc ядро, kd передаёт управление.
	#
	# Размеры чтения берутся у только что записанных файлов, с округлением
	# до стёртого блока: меньше нужного молча обрежет ядро. Дерево читается
	# первым и ниже.
	bulk "setenv ka 'setenv bootargs \${ba}'" >/dev/null || true
	bulk "setenv kb 'nand read $DTB_ADDR $DTB_OFF $dread'" >/dev/null || true
	bulk "setenv kc 'nand read $KERNEL_ADDR $KERNEL_OFF $kread'" >/dev/null || true
	bulk "setenv kd 'booti $KERNEL_ADDR - $DTB_ADDR'" >/dev/null || true

	# run принимает список, поэтому в bootcmd не нужны точки с запятой, а
	# значение с ними всё равно не собрать по кускам.
	bulk "setenv bootcmd 'run ka kb kc kd'" >/dev/null || true

	# Окно в загрузчик без USB-плясок. В стоковом окружении bootdelay нет.
	# Автозагрузка с клавишами, и она сама объявляет какими:
	#
	#   Hit Enter or space or Ctrl+C key to stop autoboot
	#
	# Отсчёт кончается на ":  0" независимо от того, ждал он или нет. И пофиг.
	if dialog --yesno "\
Оставить возможность прервать загрузку?

Да: при старте платы жмите пробел или Enter не переставая, и попадёте
в приглашение U-Boot. Другие клавиши загрузчик не слушает.

Нет: ядро стартует сразу, прервать нечем." 12 74; then
		delay=5
	else
		delay=0
	fi
	bulk "setenv bootdelay $delay" >/dev/null || true


	if dialog --defaultno --yesno "\
Включить earlycon?

Ядро начнёт печатать с первых инструкций, ещё до драйвера консоли.
Без него ядро, умершее раньше, не оставит ни строчки.

Но лог загрузки будет двоится - printk кидает
накопленное в каждую консоль, когда та регистрируется." 14 74; then
		early="earlycon=meson,0xff803000 "
	else
		early=""
	fi

	# set_long_var склеивает слова одиночными пробелами, поэтому копию для
	# сравнения надо сжать, иначе двойной пробел от пустого $early не
	# совпадёт.
	bootargs=$(printf '%s' \
		"ubi.mtd=ubi root=ubi0:rootfs rootfstype=ubifs rootwait rw ${early}console=ttyAML0,115200n8 console=ttyGS0,115200 loglevel=8" |
		tr -s ' ')

	set_long_var ba "$bootargs" ||
		{ dialog --msgbox "Не удалось задать командную строку." 7 45; return; }

	bulk "saveenv" >/dev/null || {
		dialog --title "Окружение не сохранено" --msgbox "\
saveenv не отработал.

Разделы записаны, но окружение живёт только в памяти платы и умрёт
вместе с питанием. Повторите пункт 3." 10 74
		return
	}
	item_save_env

	# env export -t выгружает ОЗУ, поэтому совпадение означает, что плата
	# приняла все команды дословно. Переживёт ли это отключение питания,
	# держится на saveenv, проверенном выше: перечитать сохранённую копию
	# без перезагрузки этот загрузчик не умеет.
	expected="$BOARDDIR/env.expected"
	{
		printf 'ba=%s\n' "$bootargs"
		printf 'ka=setenv bootargs ${ba}\n'
		printf 'kb=nand read %s %s %s\n' "$DTB_ADDR" "$DTB_OFF" "$dread"
		printf 'kc=nand read %s %s %s\n' "$KERNEL_ADDR" "$KERNEL_OFF" "$kread"
		printf 'kd=booti %s - %s\n' "$KERNEL_ADDR" "$DTB_ADDR"
		printf 'bootcmd=run ka kb kc kd\n'
		printf 'bootdelay=%s\n' "$delay"
	} >"$expected"

	wrong=""
	while IFS= read -r line; do
		grep -qxF "$line" "$BOARDDIR/env.txt" 2>/dev/null ||
			wrong="$wrong ${line%%=*}"
	done <"$expected"

	if [ -n "$wrong" ]; then
		dialog --title "Прошито, но окружение расходится" --msgbox "\
Разделы записаны, а в окружении платы не совпало:$wrong

Так плата не загрузится. Что ожидалось и что получилось:

  $expected
  $BOARDDIR/env.txt

Повторите пункт 3." 14 76
		return
	fi

	dialog --title "Прошито" --msgbox "\
Записано: ядро, дерево устройств$([ "$with_ubi" = 1 ] && echo " и рутфс").

Окружение сохранено и сверено по значениям: ba, ka, kb, kc, kd,
bootcmd, bootdelay. Прочитано обратно в

  $BOARDDIR/env.txt" 12 76

	dialog --yesno "Перезагрузить плату?" 7 58 &&
		reboot_board
}

item_recovery() {
	require_files "Что нужно для аварийной загрузки" "$RECOVERY" "$DTB"

	[ -f "$RECOVERY" ] || {
		dialog --msgbox "\
Образа аварийной системы нет. Положите его сюда:

  $RECOVERY

Это ядро, собранное с рутфсом внутри." 14 74
		return
	}

	# Тот же заголовок, что и у прошиваемого ядра, и по той же причине: booti
	# кладёт образ по SDRAM_BASE + text_offset, а SDRAM_BASE здесь ноль.
	image_is_adapted "$RECOVERY" || {
		dialog --msgbox "\
У $RECOVERY нулевой text_offset." 11 74
		return
	}

	ensure_online || return

	if [ "$dry_run" = 1 ]; then
		dialog --msgbox "сухой прогон: отправил бы $RECOVERY в ОЗУ" 7 58
		return
	fi

	mwrite_to_ram "$RECOVERY" "$KERNEL_ADDR" "аварийное ядро" || return
	mwrite_to_ram "$DTB" "$DTB_ADDR" "дерево устройств" || return

	# booti вызывает image_setup_libfdt, а тот переписывает /chosen/bootargs
	# из окружения. Только на эту сессию, без saveenv.
	set_long_var bootargs \
		"rootfstype=ramfs earlycon=meson,0xff803000 console=ttyGS0,115200 console=ttyAML0,115200n8 rdinit=/init loglevel=8 ignore_loglevel" ||
		{ dialog --msgbox "Не удалось задать командную строку." 7 45; return; }

	# Не через aml_ok: как только ядро возьмёт управление, U-Boot перестанет
	# обслуживать USB, и что ответит эта команда, не значит ничего.
	dialog --infobox "Передаю управление ядру..." 5 40
	aml_raw bulkcmd "booti $KERNEL_ADDR - $DTB_ADDR" >/dev/null 2>&1 || true

	ONLINE=0

	dialog --title "Аварийная система работает" --msgbox "\
Плата работает под Linux в RAM. NAND не используется" 20 74
}

# Стоковая система одним заходом
restore_warn_screen() {
	dialog --title "Что чем является" --msgbox "\
AML reserved      ключи, deviceid и serial этого аппарата плюс
                  таблица плохих блоков этой микросхемы
bootloader tpl    загрузочная цепочка
misc              флаг перезагрузки, ничего не чинит
boot_a boot_b     ядра
system_a system_b рутфсы
data              ваше и только ваше: аккаунт, сеть, настройки

Отсюда правило: возвращать надо ядра, рутфсы и data. Остальное на
рабочей плате уже нормальное, и переписать это - риск.

AML reserved в списке нет - ибо прошивка чужого чревата." 19 74
}

item_restore_stock() {
	local part sys="" boot="" missing="" write="" prompt opts=() pick
	local answer done_n=0 fail="" need=() src srcname kind extra

	ensure_online || return

	dialog --infobox "Читаю окружение платы..." 5 40
	detect_kind

	kind=$(dialog --title "Что возвращаем" --menu "\
Что заливаем на плату?

Сейчас на плате, судя по окружению, $DETECTED_WHAT." 12 70 2 \
		stock  "сток разделы из бэкапа или из stock" \
		alpine "альпайн, kernel dtb ubi из бэкапа" \
		3>&1 1>&2 2>&3) || return

	if [ "$kind" = alpine ]; then
		restore_ours
		return
	fi

	# Бэкап - для этой платы, а папка stock несёт чужое состояние во
	# всём, кроме системных разделов.
	opts=()
	[ -n "$(ls -A "$STOCK_DUMP" 2>/dev/null)" ] &&
		opts+=(1 "Из бэкапа этой платы   снят пунктом 0")
	[ -n "$(ls -A "$STOCK" 2>/dev/null)" ] &&
		opts+=(2 "Из папки stock         эталонные образы у скрипта")

	[ "${#opts[@]}" -gt 0 ] || {
		dialog --msgbox "\
Брать неоткуда: бэкапа этой платы нет, папки stock тоже.

Снимите бэкап пунктом 0 или положите образы разделов в

  $STOCK" 11 74
		return
	}

	pick=$(dialog --title "Возврат на сток" --menu "\
Откуда брать разделы?" 12 74 "$(( ${#opts[@]} / 2 ))" \
		"${opts[@]}" 3>&1 1>&2 2>&3) || return

	case "$pick" in
	1) src="$STOCK_DUMP"; srcname="бэкап этой платы" ;;
	2) src="$STOCK";         srcname="папка stock" ;;
	*) return ;;
	esac

	stock_map_screen
	restore_warn_screen
	rsv_what_screen

	for part in $VENDOR_PARTS; do
		need+=("$src/$part.bin")
	done
	require_files "Что нужно для возврата на сток" "${need[@]}"

	for part in $VENDOR_PARTS; do
		if [ -s "$src/$part.bin" ]; then
			case $part in
			bootloader|tpl) boot="$boot $part" ;;
			*)              sys="$sys $part" ;;
			esac
		else
			missing="$missing $part"
		fi
	done

	prompt="Вернуть плату на сток одним заходом: разделы и bootcmd.
Источник: $srcname

Всё, что записано после, будет потеряно."

	[ -n "$missing" ] && prompt="$prompt

Набор неполный, не хватает:$missing
Эти разделы останутся как есть."

	if [ -z "$sys$boot" ]; then
		dialog --defaultno --yesno "$prompt

Писать нечего. Вернуть один bootcmd?" 14 74 || return
		restore_bootcmd
		dialog --msgbox "Готово, bootcmd снова стоковый." 7 45
		return
	fi

	# По умолчанию отмечено: ядра, рутфсы, data.
	# Остальное снято, потому что на рабочей плате
	# оно уже верное.
	opts=()
	for part in $sys $boot; do
		case $part in
		boot_a|boot_b|system_a|system_b|data) opts+=("$part" "нужно" on) ;;
		*)                                    opts+=("$part" "уже правильное" off) ;;
		esac
	done

	write=$(dialog --title "Что записать" --checklist "$prompt" \
		20 74 8 "${opts[@]}" 3>&1 1>&2 2>&3) || return

	[ -n "$write" ] || {
		dialog --msgbox "Ничего не выбрано, ничего не записано." 7 48
		return
	}

	extra=""
	for part in $write; do
		case $part in
		boot_a|boot_b|system_a|system_b|data) ;;
		*) extra="$extra $part" ;;
		esac
	done

	if [ -n "$extra" ]; then
		answer=$(dialog --title "Это не то, что чинят" --inputbox "\
Выбрано сверх нужного:$extra

На рабочей плате эти разделы уже правильные, и именно они, пока
целы, оставляют дорогу назад через USB.

Наберите  i know what i am doing  чтобы продолжить." 14 70 "" \
			3>&1 1>&2 2>&3) || return

		case "$(printf '%s' "$answer" | tr 'A-Z' 'a-z')" in
		"i know what i am doing") ;;
		*) dialog --msgbox "Не подтверждено. Ничего не изменилось." 7 44
		   return ;;
		esac
	fi

	for part in $write; do
		dialog --infobox "Восстанавливаю $part..." 5 40
		if aml_ok mwrite "$src/$part.bin" store "$part" normal >/dev/null; then
			done_n=$((done_n + 1))
		else
			fail="$fail $part"
		fi
	done

	dialog --infobox "Возвращаю bootcmd..." 5 40
	restore_bootcmd

	prompt="Восстановлено разделов: $done_n.
bootcmd снова стоковый."
	[ -n "$fail" ] && prompt="$prompt

Не записались:$fail"
	[ -n "$missing" ] && prompt="$prompt

Так и не нашлось:$missing"

	dialog --title "Возврат на сток" --msgbox "$prompt

Вырубайте плату, подключайте блок питания и тестируйте сток." 16 74
}

# Плата возвращается на свою прошивку, а наша копия окружения перестаёт про врать.
restore_bootcmd() {
	bulk "setenv bootcmd 'run storeboot'" >/dev/null || true
	bulk "saveenv" >/dev/null || true
	item_save_env
}

# Шелл вендор не дает.
#
# U-Boot вываливается в приглашение, когда bootcmd кончается ничего
# не загрузив. Стоковый bootcmd не кончается, он падает в режим прошивки,
# поэтому подменяем его на команду, которая возвращается.
item_uboot_shell() {
	ensure_online || return

	dialog --defaultno --yesno "\
Оставить плату в приглашении U-Boot на последовательном порту?

bootcmd будет заменён на пустую команду, плата тут же перезагрузится
и, ничего не загрузив, отдаст приглашение. Сама она после этого не
стартует." 14 72 || return

	bulk "setenv bootcmd 'echo'" >/dev/null || true
	bulk "saveenv" >/dev/null || true
	item_save_env

	reboot_board

	dialog --title "Шелл U-Boot" --msgbox "\
Смотрите в последовательный порт: появится

  axg_s420_v2#" 11 72

	return 0
}

# reset имеет смысл, только пока плата в режиме прошивки; как только он
# отработает, тул теряет устройство. LEAVE смотрит цикл, чтобы следующий
# пункт не начался с поиска платы, которой уже нет на шине.
reboot_board() {
	dialog --infobox "Перезагружаю плату..." 5 40
	bulk "reset" >/dev/null 2>&1 || true
	ONLINE=0
	LEAVE=1
}

item_reboot() {
	ensure_online || return 1

	dialog --defaultno --yesno "\
Перезагрузить плату и выйти?" 11 70 || return 1

	reboot_board
	return 0
}

# --------------------------------------------------------------------- меню

# Считаем: чтение приходит короче на стёртый блок за каждый плохой. Разделы,
# которые не прочитались вовсе, пропускаем - пустой файл дал бы сотни.
dump_bad_blocks() {
	local part got n=0

	for part in $VENDOR_PARTS; do
		got=$(stat -Lc%s "$STOCK_DUMP/$part.bin" 2>/dev/null) || continue
		[ "$got" -gt 0 ] || continue
		n=$(( n + (VPART_SIZE[$part] - got) / ERASE_BLOCK ))
	done

	printf '%s' "$n"
}

header() {
	[ -n "$BOARD" ] || { echo "платы нет"; return; }

	printf 'плата       %s   (%s)\n' "$BOARD" \
		"$([ "$ONLINE" = 1 ] && echo "в режиме прошивки" || echo "НЕ НА ШИНЕ")"
	printf 'прошивка    %s\n' "${FW:-?}"
	# Показываем только когда дамп есть.
	if [ -n "$(ls -A "$STOCK_DUMP" 2>/dev/null)" ]; then
		printf 'бэкап       снят   (бэдов %s)' "$(dump_bad_blocks)"
	else
		printf 'бэкап       нет    (бэды неизвестны)'
	fi
}

# dialog схлопывает настоящие переводы строк, если не сказать
# --no-collapse сохраняет пробелы, которыми выровнены столбцы.
export DIALOGOPTS="--cr-wrap --no-collapse"

preflight() {
	local t pkg out report pkgs
	declare -A missing=()

	command -v dialog >/dev/null ||
		die "нет dialog. Ставится: apt install dialog"

	for t in python3 awk sed grep clear mkdir rm mv ls cat sleep wc head \
		 basename date mktemp touch stat od dd tr; do
		command -v "$t" >/dev/null && continue
		case $t in
		python3)  pkg=python3 ;;
		awk)      pkg=gawk ;;
		sed|grep) pkg=$t ;;
		clear)    pkg=ncurses-bin ;;
		*)        pkg=coreutils ;;
		esac
		missing[$pkg]="${missing[$pkg]:-}${missing[$pkg]:+ }$t"
	done

	if [ "${#missing[@]}" -gt 0 ]; then
		report=""; pkgs=""
		for pkg in "${!missing[@]}"; do
			report="$report
  $(printf '%-11s %s' "$pkg" "${missing[$pkg]}")"
			pkgs="$pkgs $pkg"
		done
		die "в системе не хватает программ:
$report

  apt install$pkgs"
	fi

	[ -x "$UPDATE" ] || die "вендорский тул не найден: $UPDATE
  положите его рядом со скриптом под именем update"

	# -x говорит «исполняемый», а не «запускается»: этот динамический и
	# хочет libusb. Отсутствие библиотеки выглядит как ошибка загрузчика
	# образов, а не как отсутствующий файл.
	out="$("$UPDATE" 2>&1 </dev/null || true)"
	case $out in
	*"error while loading shared libraries"*)
		die "вендорский тул не запускается:
  ${out%%$'\n'*}
  скорее всего нужен libusb: apt install libusb-0.1-4" ;;
	esac
}

preflight
mkdir -p "$BOARDS"

# До меню, а не внутри каждого пункта, чтобы шапка называла плату с первого
# кадра.
while ! connect; do
	dialog --yesno "Плата не ответила.\n\nПовторить?" 8 40 || { clear; exit 1; }
done

while :; do
	choice=$(dialog --title "Прошивальщик VK Mini A113X$([ "$dry_run" = 1 ] && echo ' , СУХОЙ ПРОГОН')" \
		--no-collapse --cancel-label Выход \
		--menu "$(header)" 21 74 9 \
		0 "Снять бэкап платы           все разделы" \
		1 "Опросить шину i2c           что распаяно на плате" \
		2 "Показать envs               что на плате прямо сейчас" \
		3 "Прошить alpine c k6.18      ядро, dtb, рутфс, envs" \
		4 "Грузить k6.18 с ram rootfs  для рекавери работ" \
		5 "Прошить бекап               стока или альпайна" \
		6 "Открыть U-Boot шел          на serial" \
		7 "Перезагрузить плату         и выйти" \
		8 "Выход                       просто выйти" \
		3>&1 1>&2 2>&3) || break

	case "$choice" in
	0) item_backup ;;
	1) item_inventory ;;
	2) item_show_env ;;
	3) item_flash ;;
	4) item_recovery ;;
	5) item_restore_stock ;;
	6) item_uboot_shell ;;
	7) item_reboot ;;
	8) break ;;
	esac

	[ "$LEAVE" = 1 ] && break
done

clear
[ -n "$BOARDDIR" ] && echo "журнал сессии: $BOARDDIR/session.log"
