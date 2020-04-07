#!/bin/bash
# usage:
#   video-stream.sh [WIDTH [HEIGHT [FPS [KBPS [URL [STREAMKEY [FLAGS]]]]]]]
#
# where:
#   WIDTH, HEIGHT, FPS: are integers describing the desired output stream
#   KBPS: is an integer describing the desired bitrate in kilobits-per-sec
#   URL: overrides the stream URL in the config file
#   STREAMKEY: overrides the stream key in the config file
#   FLAGS: overrides a list of flags to enable
#     audio - enable audio source multiplexing
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
config[flags]="${FLAGS}"
config[audio]="${AUDIO}"                # device identifier selected from $(aplay -l | grep 'card.*device')
config[latency]=${LATENCY_MS}           # override computed latency
config[audio_encoders]="${AUDIO_ENCODERS}"  # list of audio encoders to use
config[video_encoders]="${VIDEO_ENCODERS}"  # list of video encoders to use
# NB: the exact ratio of the max-size-time parameter between the flvmux latency
#     and the audio buffer is still a subject of investigation.  Empirical
#     results show that 5:1 can work for minimum-latency applications, but 10:10
#     is more robust for broadcast applications.
if [ -z "${config[latency]}" ] ; then
	# user desires minimum latency
	config[audmux_ratio]=5
	config[flvmux_ratio]=1
else
	# user desires broadcast robustness
	config[flvmux_ratio]=10
	config[audmux_ratio]=10
fi
# allow for command-line override
config[width]=${1:-${config[width]}}
config[height]=${2:-${config[height]}}
config[fps]=${3:-${config[fps]}}/1
config[kbps]=${4:-${config[kbps]}}      # NB: only loosely connected to what you actually get...
config[url]=${5:-${URL}}
config[streamkey]=${6:-${SKEY}}
config[flags]="${7:-${config[flags]}}"
# defaults and flags
_FLG="audio,debug,h264,mjpg,preview,rtmp,speedtest,udp,xraw"
declare -A enable
for k in $(IFS=',';echo $_FLG) ; do
	if [ -z "$(echo ${config[flags]} | grep -E $k)" ] ; then enable[$k]=false ; else enable[$k]=true ; fi
done

# gstreamer pipeline segments
declare -A gst
gst[version]=$(gst-launch-1.0 --version | head -1)
gst[encoder_conversion]=""

# Define Encoder Pipelines
declare -A encoder
declare -A encoder_formats
if [ -z "${config[video_encoders]}" ] ; then
	config[video_encoders]="imxipuvideotransform,omxh264enc,avenc_h264_omx,x264enc"
fi
if [ -z "${config[audio_encoders]}" ] ; then
	config[audio_encoders]="avenc_aac,voaacenc"
fi

# i.MX6
encoder[imxipuvideotransform]="imxipuvideotransform ! imxvpuenc_h264 bitrate=${config[kbps]} idr-interval=$((${config[fps]} * 2))"
encoder_formats[imxipuvideotransform]='I420|NV12|GRAY8'
# Ubuntu, RPi
encoder[avenc_h264_omx]="avenc_h264_omx bitrate=$((${config[kbps]} * 1000)) pass=cbr profile=main threads=auto keyint-min=$((${config[fps]} * 2))"
encoder_formats[avenc_h264_omx]='I420'
# NVIDIA, RPi variants
encoder[omxh264enc]="omxh264enc target-bitrate=$((${config[kbps]} * 1000)) control-rate=variable-skip-frames periodicity-idr=$((${config[fps]} * 3))"
encoder_formats[omxh264enc]='I420'
# Software encoders (most every system)
encoder[x264enc]="x264enc bitrate=${config[kbps]} speed-preset=veryfast tune=zerolatency key-int-max=$((${config[fps]} * 2))"
encoder_formats[x264enc]='I420|YV12|Y42B|Y444|NV12'
# Audio encoders
encoder[avenc_aac]="avenc_aac threads=auto bitrate=128000"
encoder_formats[avenc_aac]='F32LE'
encoder[voaacenc]="voaacenc bitrate=128000"
encoder_formats[voaacenc]='S16LE'

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
if [ -z "${config[latency]}" ] ; then
	# user desires minimum latency
	if [ $fps -le 0 ] ; then qmst=1000000 ; else qmst=$(( (2000/$fps + 1) * 1000000 )) ; fi
else
	# user desires broadcast robustness
	qmst=$((${config[latency]} * 1000000))
fi

# Common parts for gst spells
function flvmux {
	local result="queue max-size-time=$qmst leaky=upstream ! mux.video flvmux streamable=true name=mux latency=$(($qmst * ${config[flvmux_ratio]}))"
	echo $result
}
function h264args {
	local result="\"video/x-h264,profile=(string)main,stream-format=(string)byte-stream,width=(int)$1,height=(int)$2,framerate=(fraction)$3\" ! h264parse"
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
	local result="timeoverlay halignment=left valignment=top ypad=$(($pad * 2 + 25)) ! textoverlay halignment=left valignment=top ypad=$(($pad * 1 + 25)) name=$4 text=\"$5\" ! textoverlay halignment=left valignment=top ypad=25 text=\"${gst[version]}, $1 x $2 @$3\""
	echo $result
}


# RTMP to ${URL}/${SKEY}
# NB: it seems that one of the keys to getting audio/video interleaving is to put
#     the flvmux into its own gstreamer thread and not making it part of the video pipeline
#     Also, latency needs to be specified
if ${enable[rtmp]} ; then
	if [ -z "${username}" -o -z "${key}" ] ; then
		gst[rtmpsink]="$(flvmux) ! rtmpsink location=\"${config[url]}/${config[streamkey]} live=1 flashver=FME/3.0%20(compatible;%20FMSc%201.0)\""
	else
		gst[rtmpsink]="$(flvmux) ! rtmpsink location=\"${config[url]}/${config[streamkey]}?username=${username}\&password=${key}\""
	fi
else
	# must instantiate a mux that has sink templates of .audio and .video
	gst[rtmpsink]="$(flvmux) ! fakesink"
fi

# Sync with server
if [ -z "${URL}" ] ; then
	LOG NO URL configured, fake rtmpsink
	gst[rtmpsink]="$(flvmux) ! fakesink"
else
	response=false
	if [ -z "${SERVER}" ] ; then _ARG="" && SERVER="internet" ; else _ARG="socket ${SERVER}" ; fi
	LOG SYNC with ${SERVER}
	while true ; do
		if x=$(python /usr/local/bin/internet.py ${_ARG}) ; then response=true ; break ; fi
		sleep 5
	done
	if ! $response ; then
		LOG NO response from ${SERVER}, fake rtmpsink
		gst[rtmpsink]="$(flvmux) ! fakesink"
	fi
fi
# Ensure credentials were provided else, cancel the RTMP stream
if [ -z "${URL}" -o -z "${SKEY}" ] ; then
	LOG NO url or stream id, fake rtmpsink
	gst[rtmpsink]="$(flvmux) ! fakesink"
fi

# Determine which device we will use
LOG SCAN
# Determine which video encoder we will use
for e in $(IFS=',';echo ${config[video_encoders]}) ; do
    LOG TRY $e
	if gst-inspect-1.0 $e >> $log ; then
        LOG SELECT $e
        gst[encoder]=${encoder[$e]}
        gst[encoder_formats]=${encoder_formats[$e]}
        break
    fi
done
if [ -z "${gst[encoder]}" -o -z "${gst[encoder_formats]}" ] ; then
    LOG NO Encoder available - pipeline will fail
    gst[encoder]="queue"
fi

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
			gst[encoder_conversion]="autovideoconvert !"
			break
		fi
	fi
done

# audio devices
# NB: buffer management and sync can cause all kinds of problems including the dreaded
# ERROR                   rtmp :0:: WriteN, RTMP send error 104 (25 bytes)
# NB: in conjunction with flvmux in its own thread, it is also necessary to
#     add extra buffering after encoding the audio to allow the flvmux to
#     correctly match up the time.  This helps to avoid the above send errors.
# NB: devices constantly move around.  One cannot pick them, rather you have to choose from the list du-jour
if ${enable[audio]} ; then
	aplay -l | grep 'card.*device' | grep "${config[audio]}" | while read p || [[ -n $p ]] ; do
		# BEWARE: this is running in a separate shell, changes to the parent environment do not persist
		c=$(echo $p | cut -f1 -d, | cut -f1 -d: | cut -f2 -d' ')
		d=$(echo $p | cut -f2 -d, | cut -f1 -d: | cut -f3 -d' ')
		LOG TRY "hw:${c},${d}"
		gst-launch-1.0 -v alsasrc device="hw:${c},${d}" num-buffers=0 ! fakesink 2>&1 | sed -une '/src: caps/ s/[:;] /\n/gp' > /tmp/audio.$$
		if grep S16LE /tmp/audio.$$ && ${enable[audio]} ; then
			echo "hw:${c},${d}" > $logdir/gst.audio.dev.$$
		fi
	done
	if x=$(cat $logdir/gst.audio.dev.$$) ; then
		if [ -z "$x" ] ; then
			LOG NO audio ${config[audio]} because /tmp/audio.$$ had no suitable capabilities
		else
			dev[audio]="$x"
			LOG SELECT "${dev[audio]} for ${config[audio]}"
		fi
	else
		LOG NO audio ${config[audio]} because $logdir/gst.audio.dev.$$ was not read
	fi
fi

# Determine which audio encoder we will use
for e in $(IFS=',';echo ${config[audio_encoders]}) ; do
	LOG TRY $e
	if gst-inspect-1.0 $e >> $log ; then
		LOG SELECT $e
		x=$(echo S16LE | grep -E ${encoder_formats[$e]})
		if [ -z "$x" ] ; then
			gst[audiopipeline]="alsasrc device=\"${dev[audio]}\" ! \"audio/x-raw,format=(string)S16LE,rate=(int)44100,channels=(int)1\" ! audioconvert ! ${encoder[$e]} ! aacparse ! queue max-size-time=$(($qmst * ${config[audmux_ratio]})) ! mux.audio"
		else
			gst[audiopipeline]="alsasrc device=\"${dev[audio]}\" ! \"audio/x-raw,format=(string)S16LE,rate=(int)44100,channels=(int)1\" ! ${encoder[$e]} ! aacparse ! queue max-size-time=$(($qmst * ${config[audmux_ratio]})) ! mux.audio"
		fi
		break
	fi
done
if [ -z "${gst[audiopipeline]}" ] && ${enable[audio]} ; then
	LOG NO Audio encoder available
fi

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
	gst[sourcepipeline]="videotestsrc is-live=true ! $(xrawargs ${config[width]} ${config[height]} ${config[fps]}) ! $(overlay ${config[width]} ${config[height]} ${config[fps]} overlay \"${gst[encoder]}\") ! autovideoconvert ! ${gst[encoder]}"
fi

# perform a speedtest before launching the pipeline if so configured
if ${enable[speedtest]} ; then
	LOG DEBUG speedtest...
	x=$(/usr/local/bin/speedtest-cli --no-download --single --json)
	echo $x | python -c "import json,sys ; x=json.load(sys.stdin) ; print(json.dumps(x,indent=2))" >> $log
	# analyze upload kbps
	ul=$(echo $x | python -c "import json,sys ; x=json.load(sys.stdin) ; print(int(x['upload']))")
	min_ul=$((${config[kbps]} * 1100))  # 10% over minimum bit rate, in bps
	if [[ $ul -lt $min_ul ]] ; then
		message="$ul bps is less then minimum ($min_ul)"
	else
		message="upload speed is $(($ul / 1000)) kpbs (need $(($min_ul / 1000)) kbps)"
	fi
	LOG INFO $message
else
	message="Upload speedtest not selected"
fi

# 2nd Sink for diagnostics/file recording
if ${enable[preview]} ; then
	gst[filesink]="queue max-size-time=$qmst ! $(overlay ${config[width]} ${config[height]} ${config[fps]} message \"$message\") ! progressreport ! fpsdisplaysink sync=false video-sink=autovideosink"
else
	gst[filesink]="queue max-size-time=$qmst ! progressreport ! fakesink"
fi

# Cast gstreamer spell
# http://gstreamer-devel.966125.n4.nabble.com/Does-Gstreamer-has-a-element-that-can-split-one-stream-into-two-td966351.html
# https://serverfault.com/a/975753
# https://stackoverflow.com/questions/59085054/gstreamer-issue-with-adding-timeoverlay-on-rtmp-stream
echo "GST_DEBUG=1 G_DEBUG=fatal-criticals gst-launch-1.0 ${gst[sourcepipeline]} ! $(h264args ${config[width]} ${config[height]} ${config[fps]}) ! tee name=t t. ! ${gst[rtmpsink]} t. ! ${gst[filesink]} ${gst[audiopipeline]}" > $logdir/gst.cmd.$$
LOG BEGIN $sourceinfo ${config[kbps]} kbps $logdir/gst.cmd.$$
cat $logdir/gst.cmd.$$
if ${enable[debug]} ; then exit 0 ; fi
if ! source $logdir/gst.cmd.$$ ; then
	exit 1
fi
