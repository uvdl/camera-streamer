#!/bin/bash
# usage:
#   ensure-gst.sh [--dry-run]
#
# Ensure that all gstreamer dependencies/modules needed are installed

SUDO=$(test ${EUID} -ne 0 && which sudo)
if [ "$1" == "--dry-run" ] ; then SUDO="echo ${SUDO}" ; fi
if ! GST_VERSION=$(gst-launch-1.0 --version | head -1 | cut -f3 -d' ') ; then
	# Core modules needed for gst-inspect-1.0
	$SUDO apt-get install -y gstreamer1.0-tools gstreamer1.0-doc
	if ! GST_VERSION=$(gst-launch-1.0 --version | head -1 | cut -f3 -d' ') ; then
		exit 1
	fi
fi

echo "gstreamer version ${GST_VERSION}"

declare -A pkgdeps
if [ "${PLATFORM}" == "IMX6" ] ; then
	true
elif [ "${PLATFORM}" == "RPIX" ] ; then
	pkgdeps[gstreamer1.0-gl]=true
	pkgdeps[gstreamer1.0-omx-rpi]=true
	pkgdeps[gstreamer1.0-opencv]=true
	pkgdeps[gstreamer1.0-rtsp]=true
	pkgdeps[gstreamer1.0-vaapi]=true
elif [ "${PLATFORM}" == "NVID" ] ; then
	true
else
	pkgdeps[gstreamer1.0-libav]=true
	pkgdeps[h264enc]=true
fi

# gstreamer pipeline segments
declare -A gst
gst[aacparse]=gstreamer1.0-plugins-good
gst[alsasrc]=gstreamer1.0-alsa
gst[audioconvert]=gstreamer1.0-plugins-base
#gst[autoaudiosink]=gstreamer1.0-plugins-bad
gst[autovideoconvert]=gstreamer1.0-plugins-bad
#gst[autovideosink]=gstreamer1.0-plugins-bad
#gst[avenc_aac]=gstreamer1.0-libav
#gst[avenc_h264_omx]=gstreamer1.0-libav
gst[fpsdisplaysink]=gstreamer1.0-plugins-bad
gst[flvmux]=gstreamer1.0-plugins-good
gst[imxipuvideotransform]=
gst[jpegdec]=gstreamer1.0-plugins-good
gst[omxh264enc]=
gst[progressreport]=gstreamer1.0-plugins-good
gst[rtmpsink]=gstreamer1.0-plugins-bad
gst[textoverlay]=gstreamer1.0-plugins-base
gst[timeoverlay]=gstreamer1.0-plugins-base
gst[v4l2src]=gstreamer1.0-plugins-good
gst[videotestsrc]=gstreamer1.0-plugins-base
gst[voaacenc]=gstreamer1.0-plugins-bad
gst[x264enc]=gstreamer1.0-plugins-ugly

for e in ${!gst[@]} ; do
	mod=${gst[$e]}
	if [ -z "$mod" ] ; then continue ; fi
	pkgdeps[$mod]=true
done

#echo "PKGDEPS=${!pkgdeps[@]}"

# with dry-run, just go thru packages and return an error if some are missing
if [ "$1" == "--dry-run" ] ; then
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
$SUDO apt-get install -y ${!pkgdeps[@]}

# Ensure video encoding capability
declare -A encoder
if [ "${PLATFORM}" == "IMX6" ] ; then
	encoder[imxvpuenc_h264]=false
elif [ "${PLATFORM}" == "RPIX" ] ; then
	encoder[avenc_h264_omx]=false
	encoder[v4l2h264enc]=false
elif [ "${PLATFORM}" == "NVID" ] ; then
	encoder[omxh264enc]=false
	encoder[omxh265enc]=false
else
	encoder[x264enc]=false
	encoder[x265enc]=false
fi
any=false
for m in ${!encoder[@]} ; do
	if gst-inspect-1.0 $m > /tmp/$$.info ; then
		encoder[$m]=true
		any=true
	fi
	echo "encoder[$m]=${encoder[$m]}"
done
if ! $any ; then
	echo "No encoders detected - gst not installed correctly"
	exit 1
fi
