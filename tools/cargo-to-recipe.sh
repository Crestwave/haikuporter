#!/usr/bin/env bash

term() (
	[ -z $rc ] && return $?
	if [ $rc -ne 0 ]; then
		printf '%s' "${@+$'\e[31mError: \e[0m'$@$'\n'}" 1>&2
	else
		printf '%s' "${@+$@$'\n'}"
	fi
	[[ $usage -eq 1 ]] && eval "cat <<- EOF $([ $rc -ne 0 ] && echo "1>&2")
	Usage: $0 [options] URI category/port

	Creates a recipe template for a crates.io package, filled with
	information at hand.

	Options:
	  -h, --help	show this help message and exit
	  -k, --keep	keep the generated temporary directory
	  -psd, --print-source-directories
	 		also print SOURCE_DIR's
	  -c CMD, --cmd=CMD
	 		specify the command runtime
	  -b PORT, --bump PORT
	 		bump the crates.io dependencies of the specified port
	EOF"
	kill -s TERM $$
)

unset rc bump
trap 'trap - 15; return $rc 2> /dev/null; exit $rc' TERM
shopt -s expand_aliases
alias die='rc=$?; term'

keep() { rm -rf "$tempdir"; }

. "$(finddir B_USER_SETTINGS_DIRECTORY)"/haikuports.conf
psd=2
args=1
while (( args > 0 )); do
	case "$1" in
		""|-h|--help)
			test -n "$1"
			usage=1 die
			;;
		-k|--keep)
			keep() { echo "Kept $tempdir"; }
			shift
			;;
		-psd|--print-source-directories)
			psd=3
			shift
			;;
		-c|--cmd=*)
			[ "$1" = -c ] && shift
			cmd=${1#*=}
			shift
			;;
		-b|--bump)
			[ "$1" = -b ] && shift
			portName=${1#*=}
			directory=$(
				find "$TREE_PATH" -mindepth 3 -maxdepth 3 \
					-iname "$portName-*.*.recipe" |
					awk 'FNR == 1 { gsub("/[^/]*$", "")
							print }'
			)
			bump=1
			shift
			;;
		*://*)
			SOURCE_URI=$1
			shift
			;;
		*-*/*)
			directory="$TREE_PATH"/"$1"
			portName=$(sed 's/-/_/g' <<< "${1#*/}")
			shift
			;;
		*)
			false
			usage=1 die "Invalid category/portname"
	esac
	args=$#
done

mkdir -p "$directory"/download
cd "$directory" || die "Invalid port directory."
trap 'cd $OLDPWD; trap - 0 RETURN' EXIT RETURN

if [[ $bump -eq 1 ]]; then
	set -- "$portName"*-*.recipe
	eval "recipe=\${$#}"

	portVersionedName=${recipe%.*}
	portVersion=${portVersionedName##*-}

	getPackagePrefix() { :; }
	defineDebugInfoPackage() { :; }

	eval "$(cat "$recipe")" || die "Sourcing the recipe file failed."
fi

while true; do
	case "" in
		$SOURCE_URI)
			false
			usage=1 die "SOURCE_URI is not set."
			;;
		$SOURCE_FILENAME)
			SOURCE_FILENAME=$(basename "$SOURCE_URI")
			;;
		$CHECKSUM_SHA256)
			wget -O download/"$SOURCE_FILENAME" "$SOURCE_URI" ||
				die "Invalid URI."
			CHECKSUM_SHA256=1
			;;
		$cmd)
			cmd=$portName
			;;
		*)
			break
			;;
	esac
done

[ "$CHECKSUM_SHA256" = 1 ] ||
for ((i=0; i<3; i++)); do
	echo "$CHECKSUM_SHA256  download/$SOURCE_FILENAME" | sha256sum -c \
		&& break ||
	((i<2)) && wget -O download/"$SOURCE_FILENAME" "$SOURCE_URI" \
		"$( ((i<1)) && echo '-c' )"
done || die "Checksum verification failed."

SOURCE_DIR=$(basename "$(tar --exclude="*/*" -tf download/"$SOURCE_FILENAME")")
tempdir=$(mktemp -d "$SOURCE_DIR".XXXXXX --tmpdir=/tmp)
trap 'cd $OLDPWD; keep; trap - 0 RETURN' EXIT RETURN
tar --transform "s|$SOURCE_DIR[^/]*|${tempdir##*/}|" -C /tmp \
	-xf download/"$SOURCE_FILENAME" --wildcards "$SOURCE_DIR*/Cargo.*" ||
	die "Invalid tar archive."

info=$(
	sed -e '0,/\[metadata\]/d
		s/checksum //
		s/(.*)//
		s/ /-/
		s/ = //
		s/"//g' "$tempdir"/Cargo.lock
)
mapfile -t crates < <(awk '{ print $1".crate" }' <<< "$info")
mapfile -t checksums < <(awk '{ print $2 }' <<< "$info")
mapfile -t uris < <(
	for crate in "${crates[@]}"; do
		echo "https://static.crates.io/crates/${crate%-*}/$crate"
	done
)

unset source_uris checksums_sha256 source_dirs merged
for i in $(seq 0 $(($(wc -l <<< "$info") - 1))); do
	j=$((i + 2))
	source_uris+=( "SOURCE_URI_$j=\"${uris[i]}\"" )
	checksums_sha256+=( "CHECKSUM_SHA256_$j=\"${checksums[i]}\"" )
	[ "$psd" -eq 3 ] && source_dirs+=("$(
		source_dir=$(basename --suffix=.crate\" "${source_uris[i]}")
		echo SOURCE_DIR_$j=\""$source_dir"\"
	)")
	merged+=( ${source_uris[i]} ${checksums_sha256[i]} ${source_dirs[i]} )
done

if [[ $bump -eq 1 ]]; then
	sed -i \
		-e '/SOURCE_URI_2/,/ARCHITECTURES/ {/^A/!d}' \
		-e "/^ARCHITECTURES/i $(printf '%s\n' "${merged[@]}" |
			sed '0~'"$psd"' a\\' | head -n -1 |
			sed -z 's/\n/\\n/g')" \
		-e "s/{2\.\.[0-9][0-9]}/{2..$(( $(wc -l <<< "$info") + 1 ))}/" \
		"$directory"/"$recipe"
	die
fi

toml="$tempdir"/Cargo.toml
eval "$(sed -n '/\[package\]/,/^$/ {/"""\|\[/d; s/ = /=/p}' "$toml")"
cat << end-of-file > "$tempdir"/"$portName"-"$version".recipe
SUMMARY="$(sed 's/\.$//' <<< "$description")"
DESCRIPTION="$(
	sed -n "/$(grep -o extended- "$toml")description"' = """/,/"""/ {
		s/.* """//
		/"""/d
		p
	}' "$toml"
)"
HOMEPAGE="$homepage"
COPYRIGHT=""
LICENSE="$(sed 's,/\| OR ,\n\t,; s,-\([0-9]\)\.0, v\1,' <<< "$license")"
REVISION="1"
SOURCE_URI="$(
	sed -e "s|$homepage|\$HOMEPAGE|
		s|$version|\$portVersion|" <<< "$SOURCE_URI"
)"
CHECKSUM_SHA256="$(sha256sum download/"$SOURCE_FILENAME" | cut -d\  -f1)"
SOURCE_FILENAME="$name-\$portVersion.tar.gz"

$(printf '%s\n' "${merged[@]}" | sed '0~'"$psd"' a\\')

ARCHITECTURES="!x86_gcc2 ?x86 x86_64"
commandBinDir=\$binDir
if [ "\$targetArchitecture" = x86_gcc2 ]; then
SECONDARY_ARCHITECTURES="x86"
commandBinDir=\$prefix/bin
fi

PROVIDES="
	$portName\$secondaryArchSuffix = \$portVersion
	cmd:$cmd
	"
REQUIRES="
	haiku\$secondaryArchSuffix
	"

BUILD_REQUIRES="
	haiku\${secondaryArchSuffix}_devel
	"
BUILD_PREREQUIRES="
	cmd:cargo\$secondaryArchSuffix
	cmd:gcc\$secondaryArchSuffix
	"

defineDebugInfoPackage $portName\$secondaryArchSuffix \\
	\$commandBinDir/$cmd

BUILD()
{
	export CARGO_HOME=\$sourceDir/../cargo
	CARGO_VENDOR=\$CARGO_HOME/haiku
	mkdir -p \$CARGO_VENDOR
	for i in {2..$(( $(wc -l <<< "$info") + 1 ))}; do
		eval temp=\\\$sourceDir\$i
		eval shasum=\\\$CHECKSUM_SHA256_\$i
		pkg=\$(basename \$temp/*)
		cp -r \$temp/\$pkg \$CARGO_VENDOR
		cat <<- EOF > \$CARGO_VENDOR/\$pkg/.cargo-checksum.json
		{
			"package": "\$shasum",
			"files": {}
		}
		EOF
	done

	cat <<- EOF > \$CARGO_HOME/config
	[source.haiku]
	directory = "\$CARGO_VENDOR"

	[source.crates-io]
	replace-with = "haiku"
	EOF

	cargo build --release
}

INSTALL()
{
	install -D -m755 -t \$commandBinDir target/release/$cmd
	install -D -m644 -t \$docDir README.md
}

TEST()
{
	export CARGO_HOME=\$sourceDir/../cargo
	cargo test --release
}
end-of-file
mv -i "$tempdir"/"$portName"-"$version".recipe "$directory"
