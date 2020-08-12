#!/bin/bash
# usage:
#   ensure-gstd.sh [--dry-run]
#
# Ensure that all gstd dependencies/modules needed are installed

DRY_RUN=false
LOCAL=/usr/local
GSTD=${LOCAL}/bin/gstd
GSTD_SRC=${LOCAL}/src/gstd-1.x
GSTD_TAG=v0.10.0
GST_INTERPIPE_SRC=${LOCAL}/src/gst-interpipe
GST_INTERPIPE_TAG=v1.1.1
RIDGERUN=https://github.com/RidgeRun
SUDO=$(test ${EUID} -ne 0 && which sudo)

if [ "$1" == "--dry-run" ] ; then DRY_RUN=true && SUDO="echo ${SUDO}" ; fi
if [ ! "$1" == "--update" ] ; then
	GSTD_VERSION=$(gstd --version)
	if ! [ -z "${GSTD_VERSION}" ] ; then
		gst-inspect-1.0 interpipe && echo "${GSTD_VERSION}"
		exit 0
	fi
fi

##PKGDEPS=automake host libtool pkg-config libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libglib2.0-dev libjson-glib-dev gtk-doc-tools libreadline-dev libncursesw5-dev libdaemon-dev libjansson-dev
declare -A pkgdeps
pkgdeps[automake]=true
pkgdeps[gtk-doc-tools]=true
pkgdeps[host]=true
pkgdeps[libdaemon-dev]=true
pkgdeps[libglib2.0-dev]=true
pkgdeps[libgstreamer1.0-dev]=true
pkgdeps[libgstreamer-plugins-base1.0-dev]=true
pkgdeps[libjansson-dev]=true
pkgdeps[libjson-glib-dev]=true
pkgdeps[libncursesw5-dev]=true
pkgdeps[libsoup2.4-dev]=true
pkgdeps[libreadline-dev]=true
pkgdeps[libtool]=true
pkgdeps[pkg-config]=true
pkgdeps[python3-pip]=true

# with dry-run, just go thru packages and return an error if some are missing
if $DRY_RUN ; then
	declare -A todo
	apt list --installed > /tmp/$$.pkgs 2>/dev/null	# NB: warning on stderr about unstable API
	for m in ${!pkgdeps[@]} ; do
		x=$(grep $m /tmp/$$.pkgs)
		if [ -z "$x" ] ; then
			echo "$m: missing"
			todo[$m]=true
		else
			true #&& echo "$x"
		fi
	done
	if [ "${#todo[@]}" -gt 0 ] ; then echo "Please run: apt-get install -y ${!todo[@]}" ; fi
	exit ${#todo[@]}
fi
set -e
$SUDO apt-get install -y ${!pkgdeps[@]}

if ! [ -d "${GSTD_SRC}" ] ; then
	$SUDO chmod a+w $(dirname ${GSTD_SRC}/)
	( cd $(dirname ${GSTD_SRC}/) && git clone ${RIDGERUN}/$(basename ${GSTD_SRC}).git && cd ${GSTD_SRC} && git checkout ${GSTD_TAG} )
else
	( cd ${GSTD_SRC} && git checkout ${GSTD_TAG} && rm -f Makefile configure )
fi
( cd ${GSTD_SRC} && ./autogen.sh && ./configure && make clean && make )
( cd ${GSTD_SRC} && $SUDO make install )

if ! [ -d "${GST_INTERPIPE_SRC}" ] ; then
	$SUDO chmod a+w $(dirname ${GST_INTERPIPE_SRC}/)
	( cd $(dirname ${GST_INTERPIPE_SRC}/) && git clone ${RIDGERUN}/$(basename ${GST_INTERPIPE_SRC}).git && cd ${GST_INTERPIPE_SRC} && git checkout ${GST_INTERPIPE_TAG} )
else
	( cd ${GST_INTERPIPE_SRC} && git checkout ${GST_INTERPIPE_TAG} && rm -f Makefile configure )
fi
( cd ${GST_INTERPIPE_SRC} && ./autogen.sh --libdir /usr/lib/aarch64-linux-gnu && make clean && make )
( cd ${GST_INTERPIPE_SRC} && $SUDO make install )
# https://github.com/RidgeRun/gst-interpipe/issues/49
( cd ${GST_INTERPIPE_SRC} ; set +e ; make check ; set -e )

echo "$(gstd --version)"
