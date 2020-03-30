#!/bin/bash
# usage:
#   video-stream.sh [WIDTH [HEIGHT [FPS [KBPS [SN [FLAGS]]]]]]
#
# where:
#   WIDTH, HEIGHT, FPS: are integers describing the desired output stream
#   KBPS: is an integer describing the desired bitrate in kilobits-per-sec
#   SN: overrides the serial number for this stream
#   FLAGS: overrides a list of flags to enable
#     debug - perform a dry-run and only report the pipeline that would be executed
#     rtmp - enable rtmp output to the internet (video.mavnet.online)
#     h264 - prefer H.264 source from camera
#     mjpg - fallback to Motion JPEG
#     xraw - fallback to RAW video (NB: may be bandwidth limited if using USB)
#
# TODO: https://github.com/Freescale/gstreamer-imx/issues/206
logdir=/tmp
if [ ! -d $logdir ] ; then logdir=/tmp ; fi ; log=$logdir/video.log
# configuration items (defaults)
declare -A config
config[width]=1280
config[height]=720
config[fps]=30
config[kbps]=2000
config[flags]="rtmp,h264,mjpg"
# allow for command-line override
config[width]=${1:-${config[width]}}
config[height]=${2:-${config[height]}}
config[fps]=${3:-${config[fps]}}/1
config[kbps]=${4:-${config[kbps]}}      # NB: only loosely connected to what you actually get...
config[sn]=${5:-$(python3 ${HOME}/camera-streamer/serial_number.py)}
config[flags]="${6:-${config[flags]}}"
# defaults and flags
FLAGS="debug,h264,mjpg,rtmp,xraw"
declare -A enable
for k in $(IFS=',';echo $FLAGS) ; do
	if [ -z "$(echo ${config[flags]} | grep -E $k)" ] ; then enable[$k]=false ; else enable[$k]=true ; fi
done

# Configuration for RTMP server
auth="username=${USERNAME}&password=${KEY}"
# TODO: more of this stuff can go into config[] so that it can be overriden by the provisioning/parameter system
server="mavnet.online"
port=1935
grp=live/ORNL
config[url]="rtmp://video.$server:$port/$grp/${config[sn]}?$auth"
ttl=10

# gstreamer pipeline segments
declare -A gst

gst[version]=$(gst-launch-1.0 --version | head -1)

# Define Encoder Pipeline
# i.MX6
#gst[encoder]="imxipuvideotransform ! imxvpuenc_h264 bitrate=${config[kbps]} idr-interval=60"
#gst[encoder_formats]='I420|NV12|GRAY8'
# Ubuntu, etc.
#gst[encoder]="avenc_h264_omx bitrate=$((${config[kbps]} * 1000)) me-method=epzs"
#gst[encoder_formats]='I420'
# RPi variants
gst[encoder]="omxh264enc bitrate=$((${config[kbps]} * 1000))"
gst[encoder_formats]='I420'
# Software encoders (most every system)
#gst[encoder]="x264enc bitrate=${config[kbps]} speed-preset=veryfast tune=zerolatency key-int-max=60"
#gst[encoder_formats]='I420|YV12|Y42B|Y444|NV12|YUYV'
gst[encoder_conversion]=""

# logging to file and stdout (which is journaled under systemd)
function LOG {
	mkdir -p $(dirname $log)
	echo "$(date --iso-8601='seconds') $*" >> $log
	echo "$*"
}

if ${enable[debug]} ; then
    for k in ${!config[@]} ; do
        echo "config[$k]=${config[$k]}"
    done
    for k in ${!enable[@]} ; do
        echo "enable[$k]=${enable[$k]}"
    done
    #exit 0
fi

# compute queue max-size-time parameter to avoid gstreamer
# "Impossible to configure latency" warnings/errors.  We calculate the amount
# of time for two frames at the desired frame rate (in nanoseconds).  Min 1ms.
fps=$(( ${config[fps]} ))
if [ $fps -le 0 ] ; then qmst=1000000 ; else qmst=$(( (2000/$fps + 1) * 1000000 )) ; fi

# RTMP to video.$server
if ${enable[rtmp]} ; then
	gst[rtmpsink]="queue max-size-time=$qmst leaky=upstream ! flvmux streamable=true ! rtmpsink location=\"${config[url]}\""
else
	gst[rtmpsink]="queue max-size-time=$qmst ! fakesink"
fi
# 2nd Sink for diagnostics/file recording
if true ; then
	gst[filesink]="queue max-size-time=$qmst ! fakesink"
fi

# Common parts for gst spells
function h264args {
	local result="\"video/x-h264,stream-format=(string)byte-stream,width=(int)$1,height=(int)$2,framerate=(fraction)$3\" ! h264parse"
	echo $result
}
function mjpgargs {
	local result="\"image/jpeg,width=(int)$1,height=(int)$2,framerate=(fraction)$3\""
	echo $result
}
function xrawargs {
	local result="\"video/x-raw,format=(string)I420,width=(int)$1,height=(int)$2,framerate=(fraction)$3\""
	echo $result
}
function overlay {
	local pad=25
	if [ $2 -gt 480 ] ; then pad=35 ; fi
	if [ $2 -gt 720 ] ; then pad=55 ; fi
	local result="timeoverlay halignment=left valignment=top ypad=$(($pad * 2 + 25)) ! textoverlay halignment=left valignment=top ypad=$(($pad * 1 + 25)) text=\"${gst[encoder]}\" ! textoverlay halignment=left valignment=top ypad=25 text=\"${gst[version]}, $1 x $2 @$3\""
	echo $result
}

# Sync with server
if ! ping -c 1 -W 5 $server ; then
	LOG NO $server, fake rtmpsink
	gst[rtmpsink]="queue max-size-time=$qmst ! fakesink"
fi
# Ensure credentials were provided else, cancel the RTMP stream
if [ -z "$USERNAME" -o -z "$KEY" -o -z "${config[sn]}" ] ; then
	LOG NO credentials or stream id, fake rtmpsink
	gst[rtmpsink]="queue max-size-time=$qmst ! fakesink"
fi

# Determine which device we will use
LOG SCAN
# video devices
declare -A dev
for d in /dev/video* ; do
	if v4l2-ctl -d $d --list-formats > /tmp/video.$$ ; then
		cat /tmp/video.$$
		if grep H264 /tmp/video.$$ && ${enable[h264]} ; then
			LOG H264=$d
			dev[h264]=$d
			break	# prefer H264 over MJPG/YUYV
		elif grep MJPG /tmp/video.$$ && ${enable[mjpg]} ; then
			LOG MJPG=$d
			dev[mjpg]=$d
			break   # prefer MJPG over YUYV
		elif grep -E ${gst[encoder_formats]} /tmp/video.$$ && ${enable[xraw]} ; then
			LOG XRAW=$d
			dev[xraw]=$d
			break
		elif ${enable[xraw]} ; then
			LOG XRAW=$d using autovideoconvert
			dev[xraw]=$d
			gst[encoder_conversion]="! autovideoconvert"
			break
		fi
	fi
done

# Determine source pipeline in priority: H264->MJPG->XRAW->TEST
if [ ! -z "${dev[h264]}" ] ; then
	sourceinfo="H.264 ${dev[h264]} ${config[width]} ${config[height]} ${config[fps]}"
	gst[sourcepipeline]="v4l2src device=${dev[h264]} io-mode=mmap"
elif [ ! -z "${dev[mjpg]}" ] ; then
	sourceinfo="MJPG ${dev[mjpg]} ${config[width]} ${config[height]} ${config[fps]}"
	gst[sourcepipeline]="v4l2src device=${dev[mjpg]} io-mode=mmap ! $(mjpgargs ${config[width]} ${config[height]} ${config[fps]}) ! jpegdec ! $(xrawargs ${config[width]} ${config[height]} ${config[fps]}) ! ${gst[encoder]}"
elif [ ! -z "${dev[xraw]}" ] ; then
	sourceinfo="XRAW ${dev[xraw]} ${config[width]} ${config[height]} ${config[fps]}"
	gst[sourcepipeline]="v4l2src device=${dev[xraw]} io-mode=mmap ! ${gst[encoder_conversion]} $(xrawargs ${config[width]} ${config[height]} ${config[fps]}) ! ${gst[encoder]}"
else
	sourceinfo="TEST ${config[width]} ${config[height]} ${config[fps]}"
	gst[sourcepipeline]="videotestsrc is-live=true ! $(xrawargs ${config[width]} ${config[height]} ${config[fps]}) ! $(overlay ${config[width]} ${config[height]} ${config[fps]}) ! autovideoconvert ! ${gst[encoder]}"
fi

# Cast gstreamer spell
# http://gstreamer-devel.966125.n4.nabble.com/Does-Gstreamer-has-a-element-that-can-split-one-stream-into-two-td966351.html
# https://serverfault.com/a/975753
echo "GST_DEBUG=1 G_DEBUG=fatal-criticals gst-launch-1.0 ${gst[sourcepipeline]} ! progressreport ! $(h264args ${config[width]} ${config[height]} ${config[fps]}) ! tee name=t t. ! ${gst[rtmpsink]} t. ! ${gst[filesink]}" > $logdir/gst.cmd.$$
LOG BEGIN $sourceinfo ${config[kbps]} kbps $logdir/gst.cmd.$$
cat $logdir/gst.cmd.$$
if ${enable[debug]} ; then exit 0 ; fi
if ! source $logdir/gst.cmd.$$ ; then
	exit 1
fi
