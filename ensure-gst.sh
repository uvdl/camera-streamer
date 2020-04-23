#!/bin/bash
# usage:
#   ensure-gst.sh
#
# Ensure that all gstreamer dependencies/modules needed are installed

SUDO=$(test ${EUID} -ne 0 && which sudo)
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
fi

# gstreamer pipeline segments
declare -A gst
gst[aacparse]=gstreamer1.0-plugins-good
gst[alsasrc]=gstreamer1.0-alsa
gst[audioconvert]=gstreamer1.0-plugins-base
#gst[autoaudiosink]=gstreamer1.0-plugins-bad
gst[autovideoconvert]=gstreamer1.0-plugins-bad
#gst[autovideosink]=gstreamer1.0-plugins-bad
gst[avenc_aac]=gstreamer1.0-libav
gst[avenc_h264_omx]=gstreamer1.0-libav
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

echo "PKGDEPS=${!pkgdeps[@]}"

$SUDO apt-get install -y ${!pkgdeps[@]}
