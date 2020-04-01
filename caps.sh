#!/bin/bash
# usage:
#   caps.sh [PATH [DEV]]
#
# where:
#   PATH: path to folder to collect all data files produced
#   DEV: path to v4l2 device (or enumerate all devices)

# allow for command-line overrides
declare -A config
config[path]=${1:-/tmp/caps.$$} ; shift
config[devs]=$*
if [ -z "${config[devs]}" ] ; then config[devs]=/dev/video* ; fi

mkdir -p ${config[path]}
for d in ${config[devs]} ; do
	echo "*** $d ***"
	fpart=${config[path]}/$(basename $d)
	if v4l2-ctl -d $d --list-formats > ${fpart}.fmt ; then
		v4l2-ctl -d $d --list-ctrls > ${fpart}.ctrls
		v4l2-ctl -d $d --all > ${fpart}.all
		( gst-launch-1.0 --gst-debug=v4l2src:5 v4l2src device=$d num-buffers=0 ! fakesink 2>&1 | sed -une '/caps of src/ s/[:;] /\n/gp' ) > ${fpart}.txt
	fi
done
# TODO: ALSA HW capture (for audio)
# echo "*** ALSASRC ***"
##for d in $(seq 0 9) ; do echo -n "*** hw:$d " ; if ( gst-launch-1.0 alsasrc device="hw:${d}" num-buffers=0 ! fakesink 2>&1 ) > /dev/null ; then echo "OK" ; for c in $(seq 0 9) ; do echo -n "    hw:$d,$c " | tee -a ${config[path]}/audio.txt ; if ( gst-launch-1.0 -v alsasrc device="hw:${d}" num-buffers=0 ! fakesink 2>&1 | sed -une '/src: caps/ s/[:;] /\n/gp' ) >> ${config[path]}/audio.txt ; then echo "OK, ${config[path]}/audio.txt" ; else echo "NO" ; fi ; done ; else echo "NO" ; fi ; done

lsusb > ${config[path]}/usb.lst
lsusb -v > ${config[path]}/usb.txt
gst-inspect-1.0 | sort > ${config[path]}/gst.lst

echo "*** ${config[path]}"
ls -al ${config[path]}
