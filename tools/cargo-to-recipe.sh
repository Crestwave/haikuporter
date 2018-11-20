#!/bin/bash
die() {
	printf '\e[31m%s\e[0m' "Error: " "${@+$@$'\n'}"
	[ "$usage" = 1 ] && usage
	exit 1
} 1>&2

usage() {
	cat <<- EOF
	Usage: SOURCE_URI=[uri] ./cargo-recipe.sh [options] category/portname

	Outputs the SOURCE_URI's and CHECKSUM_SHA256's of a Rust package's
	dependencies from crates.io.

	Options:
	  -h, --help	show this help message and exit
	  -k, --keep	keep the generated temporary directory
	  -psd, --print-source-directories
	 		also print SOURCE_DIR's
	EOF
}

keep() { rm -rf "$tempdir"; }

psd=2
args=1
while (( args > 0 )); do
	case "$1" in
		""|-h|--help )
			usage
			exit 0
			;;
		-k|--keep)
			keep() { echo "Kept $tempdir"; }
			shift
			;;
		-psd|--print-source-directories)
			psd=3
			shift
			;;
		*)
			. ~/config/settings/haikuports.conf
			directory="$TREE_PATH"/"$1"
			portName=$(sed 's/-/_/g' <<< "${1#*/}")
			shift
			;;
	esac
	args=$#
done

mkdir -p "$directory"/download
cd "$directory" || die "Invalid port directory."
tempdir=$(mktemp -d "$portName".XXXXXX --tmpdir=/tmp)
trap "{ cd $OLDPWD; keep; }" EXIT RETURN

#port=${recipe%.*}
#portName=${port%-*}
#portVersion=${port##*-}

case "" in
	$SOURCE_URI)
		usage=1 die "SOURCE_URI is not set."
		;;
	$SOURCE_FILENAME)
		SOURCE_FILENAME=$(basename "$SOURCE_URI")
		;;
esac

wget -O download/"$SOURCE_FILENAME" "$SOURCE_URI"
for ((i=0; i<3; i++)); do
	tar --transform "s|[^/]*|${tempdir##*/}|" -C /tmp \
		-xf download/"$SOURCE_FILENAME" --wildcards "$( ((i<2)) &&
			echo "*/Cargo.*" )" && ((i<2)) && break
	((i>1)) && {
		[ -n "$PATCHES" ] && patch -d "$tempdir" -i patches/"$PATCHES"
		(cd "$tempdir" && cargo update)
	}
done

info=$(
	sed -e '0,/\[metadata\]/d
		s/checksum //
		s/(.*)//
		s/ /-/
		s/ = //
		s/"//g' "$tempdir"/Cargo.lock
)
crates=$(awk '{ print $1".crate" }' <<< "$info")
checksums=$(awk '{ print $2 }' <<< "$info")
numbers=$(seq 2 $(($(wc -l <<< "$info") + 1)))

uris=$(
	for crate in $crates; do
		echo "https://static.crates.io/crates/${crate%-*}/$crate"
	done
)
source_uris=$(
	for i in $numbers; do
		echo SOURCE_URI_$i=\""$(sed "$((i-1))q;d" <<< "$uris")"\"
	done
)
checksums_sha256=$(
	for i in $numbers; do
		j=$((i - 1))
		echo CHECKSUM_SHA256_$i=\""$(sed "${j}q;d" <<< "$checksums")"\"
	done
)
source_dirs=$(
	eval "$source_uris"
	for i in $numbers; do
		eval source_uri=\$SOURCE_URI_$i
		source_filename=$(basename --suffix=.crate "$source_uri")
		echo SOURCE_DIR_$i=\""$source_filename"\"
	done
)

merged=$(paste -d \\n <(echo "$source_uris") <(echo "$checksums_sha256"))
if [ "$psd" = 3 ]; then
	for i in $numbers; do
		merged=$(
			echo "$merged" | sed "/CHECKSUM_SHA256_$i=\".*\"/a \
				$(sed "$((i-1))q;d" <<< "$source_dirs")"
		)
	done
fi

eval "$(sed -n '/package/,/^$/{s/ = /=/p}' "$tempdir"/Cargo.toml)"
cat << end-of-file > "$tempdir"/"$portName"-"$version".recipe
SUMMARY="$(sed 's/\.$//' <<< "$description")"
DESCRIPTION=""
HOMEPAGE="$homepage"
COPYRIGHT=""
LICENSE="$(sed 's|/|\n\t|; s|-2.0| v2|' <<< "$license")"
REVISION="1"
SOURCE_URI="$(
	sed -e "s|$homepage|\$HOMEPAGE|
		s|$version|\$portVersion|" <<< "$SOURCE_URI"
)"
CHECKSUM_SHA256="$(sha256sum download/"$SOURCE_FILENAME" | cut -d\  -f1)"
SOURCE_FILENAME="$SOURCE_FILENAME"

$(echo "$merged" | sed '0~'"$psd"' a\\')

ARCHITECTURES="!x86_gcc2 ?x86 x86_64"
commandBinDir=\$binDir
if [ "\$targetArchitecture" = x86_gcc2 ]; then
SECONDARY_ARCHITECTURES="x86"
commandBinDir=\$prefix/bin
fi

PROVIDES="
	$portName = \$portVersion
	cmd:$portName
	"
REQUIRES="
	haiku\$secondaryArchSuffix
	"

BUILD_REQUIRES="
	haiku\${secondaryArchSuffix}_devel
	"

defineDebugInfoPackage $portName\$secondaryArchSuffix \
	\$commandBinDir/$portName

BUILD()
{
	export CARGO_HOME=\$sourceDir/../cargo
	CARGO_VENDOR=\$CARGO_HOME/haiku
	mkdir -p \$CARGO_VENDOR
	for i in {2..55}; do
		eval temp=\$sourceDir\$i
		eval shasum=\$CHECKSUM_SHA256_\$i
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
	install -D -m755 -t \$commandBinDir target/release/diskus
	install -D -m644 -t \$docDir README.md
}

TEST()
{
	export CARGO_HOME=\$sourceDir\$i/../cargo
	cargo test --all
}
end-of-file
mv -i "$tempdir"/"$portName"-"$version".recipe "$directory"
