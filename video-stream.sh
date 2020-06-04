#!/bin/bash
# usage:
#   video-stream.sh [WIDTH [HEIGHT [FPS [KBPS [URL [SKEY [FLAGS]]]]]]]
#
# where:
#   WIDTH, HEIGHT, FPS: are integers describing the desired output stream
#   KBPS: is an integer describing the desired bitrate in kilobits-per-sec
#   URL: overrides the stream URL in the config file
#   SKEY: overrides the stream key in the config file
#   FLAGS: overrides a list of flags to enable
#     audio - enable audio source multiplexing
#     debug - perform a dry-run and only report the pipeline that would be executed
#     h264 - prefer H.264 source from camera
#     mjpg - fallback to Motion JPEG
#     preview - render outgoing stream on local framebuffer
#     rtmp - enable rtmp output (to the WAN)
#     scale - allow (up) scaling to reduce data rate from camera to encoder
#     single - allow either rtmp or udp not both
#     speedtest - test and document upstream WAN bandwidth before starting stream (depends on wan enable)
#     udp - enable UDP output to LAN
#     wan - enable operations on wide-area-networks (internet)
#     xraw - fallback to RAW video (NB: may be bandwidth limited if using USB)
#
# TODO: https://github.com/Freescale/gstreamer-imx/issues/206
if [ -z "${LOGDIR}" ] ; then
	## NB: RUNTIME_DIRECTORY does not seem to be populated as the systemd docs say...
	##if [ -z "$RUNTIME_DIRECTORY" ] ; then LOGDIR=/tmp ; else LOGDIR=$RUNTIME_DIRECTORY ; fi
	if [ -d /var/run/video-stream ] ; then LOGDIR=/var/run/video-stream ; else LOGDIR=/tmp/video-stream.$$ ; fi
else
	if ! mkdir -p ${LOGDIR} ; then LOGDIR=/tmp/video-stream.$$ ; fi
fi
log=${LOGDIR}/video.log
# configuration items (defaults)
declare -A config
config[width]=${WIDTH} ; if [ -z "${config[width]}" ] ; then config[width]=1280 ; fi
config[height]=${HEIGHT} ; if [ -z "${config[height]}" ] ; then config[height]=720 ; fi
config[fps]=${FPS} ; if [ -z "${config[fps]}" ] ; then config[fps]=30 ; fi
config[kbps]=${H264_BITRATE} ; if [ -z "${config[kbps]}" ] ; then config[kbps]=1800 ; fi
config[flags]="${FLAGS}"
config[audio]="${AUDIO}"                    # device identifier selected from $(aplay -l | grep 'card.*device')
config[audio_latency]=${AUDIO_LATENCY_MS}   # override computed latency
config[video_latency]=${VIDEO_LATENCY_MS}   # override computed latency
config[audio_encoders]="${AUDIO_ENCODERS}"  # list of audio encoders to use
config[video_encoders]="${VIDEO_ENCODERS}"  # list of video encoders to use
config[video_scalers]="${VIDEO_SCALERS}"    # list of video scalers to use
config[video_device]=${VIDEO_DEVICE}        # video device path to use (empty to autoselect)
config[h264_profile]=${H264_PROFILE}        # high, main, baseline or empty
config[h264_rate]=${H264_RATE}              # constant, variable or empty
# NB: the exact ratio of the max-size-time parameter between the flvmux latency
#     and the audio buffer is still a subject of investigation.  Empirical
#     results show that 5:1 can work for minimum-latency applications, but 10:10
#     is more robust for broadcast applications.
if [ -z "${config[video_latency]}" ] ; then
	# user desires minimum latency
	config[audmux_ratio]=5
	config[flvmux_ratio]=1
	config[video_latency]=0
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
# udp configuration/defaults
declare -A udp
udp[host]=${UDP_HOST} ; if [ -z "${udp[host]}" ] ; then udp[host]=224.1.1.1 ; fi
udp[iface]=${UDP_IFACE} ; if [ -z "${udp[iface]}" ] ; then udp[iface]=eth0 ; fi
udp[port]=${UDP_PORT} ; if [ -z "${udp[port]}" ] ; then udp[port]=5600 ; fi
udp[ttl]=${UDP_TTL} ; if [ -z "${udp[ttl]}" ] ; then udp[ttl]=10 ; fi
# Need to add multicast-iface if multicasting...
if [ ${udp[host]/.*} -ge 224 -a ${udp[host]/.*} -le 239 ] ; then
	udp[props]="host=${udp[host]} port=${udp[port]} multicast-iface=${udp[iface]} auto-multicast=true ttl=${udp[ttl]}"
else
	udp[props]="host=${udp[host]} port=${udp[port]}"
fi

# defaults and flags
_FLG="audio,debug,h264,mjpg,preview,rtmp,scale,single,speedtest,udp,wan,xraw"
declare -A enable
for k in $(IFS=',';echo $_FLG) ; do
	if [ -z "$(echo ${config[flags]} | grep -E $k)" ] ; then enable[$k]=false ; else enable[$k]=true ; fi
done

# gstreamer pipeline segments
declare -A gst
gst[version]=$(gst-launch-1.0 --version | head -1)
gst[videoscale]="videoscale"

# Define Encoder Pipelines
declare -A encoder
declare -A encoder_formats
if [ -z "${config[video_scalers]}" ] ; then
	config[video_scalers]="imxipuvideotransform"
fi
if [ -z "${config[video_encoders]}" ] ; then
	config[video_encoders]="imxvpuenc_h264,omxh264enc,x264enc"
fi
if [ -z "${config[audio_encoders]}" ] ; then
	#config[audio_encoders]="avenc_aac,voaacenc"
	config[audio_encoders]="voaacenc"
fi

# i.MX6
encoder[imxvpuenc_h264]="imxvpuenc_h264 bitrate=${config[kbps]} idr-interval=$((${config[fps]} * 2))"
encoder_formats[imxvpuenc_h264]='I420|NV12|GRAY8'
# RPi, NVidia handled below
# Software encoders (most every system)
encoder[x264enc]="x264enc bitrate=${config[kbps]} speed-preset=veryfast key-int-max=$((${config[fps]} * 2))"
encoder_formats[x264enc]='I420|YV12|Y42B|Y444|NV12'
# Audio encoders
encoder[avenc_aac]="avenc_aac threads=auto bitrate=128000"
encoder_formats[avenc_aac]='F32LE'
encoder[voaacenc]="voaacenc bitrate=128000"
encoder_formats[voaacenc]='S16LE'

# adjustments
if [ -z "${config[video_latency]}" -o ${config[video_latency]} -lt 1 ] ; then
	encoder[x264enc]="${encoder[x264enc]} tune=zerolatency sliced-threads=true"
fi
# RPi variations are *so* different from Ubuntu/NVidia
if [ "${PLATFORM}" == "RPIX" ] ; then
	# NB: https://www.phoronix.com/forums/forum/software/desktop-linux/864973-libav-adds-h-264-mpeg4-encoders-using-openmax-il?p=865870#post865870
	encoder[avenc_h264_omx]="avenc_h264_omx bitrate=$((${config[kbps]} * 1000)) threads=auto keyint-min=$((${config[fps]} * 2))"
	encoder_formats[avenc_h264_omx]='I420'
	if [ ! -z "${config[h264_profile]}" ] ; then
		encoder[avenc_h264_omx]="${encoder[avenc_h264_omx]} profile=${config[h264_profile]}"
	fi
	if [ "${config[h264_rate]}" == "constant" ] ; then
		encoder[avenc_h264_omx]="${encoder[avenc_h264_omx]} pass=cbr"
	elif [ "${config[h264_rate]}" == "variable" ] ; then
		encoder[avenc_h264_omx]="${encoder[avenc_h264_omx]} pass=vbr"
	fi
	# https://www.raspberrypi.org/forums/viewtopic.php?t=240170
	encoder[v4l2h264enc]="v4l2h264enc"
	encoder_formats[v4l2h264enc]='I420|YV12|NV12|RGB16|RGB|BGR|BGRA|YUY2|YVYU|UYVY'
	extra="encode,video_bitrate=$((${config[kbps]} * 1000)),h264_i_frame_period=$((${config[fps]} * 2))"
	if [ ! -z "${config[h264_profile]}" ] ; then
		extra="${extra},h264_profile=${config[h264_profile]}"
	fi
	if [ "${config[h264_rate]}" == "constant" ] ; then
		extra="${extra},video_bitrate_mode=1"
	elif [ "${config[h264_rate]}" == "variable" ] ; then
		extra="${extra},video_bitrate_mode=0"
	fi
	encoder[v4l2h264enc]="${encoder[v4l2h264enc]} extra-controls=\"${extra}\""
# NVidia variations are different from Ubuntu
elif [ "${PLATFORM}" == "NVID" ] ; then
	encoder[omxh264enc]="omxh264enc bitrate=$((${config[kbps]} * 1000)) iframeinterval=$((${config[fps]} * 2))"
	encoder_formats[omxh264enc]='I420|NV12'
	if [ "${config[h264_rate]}" == "constant" ] ; then
		encoder[omxh264enc]="${encoder[omxh264enc]} control-rate=constant"
	elif [ "${config[h264_rate]}" == "variable" ] ; then
		encoder[omxh264enc]="${encoder[omxh264enc]} control-rate=variable-skip-frames"
	fi
fi

# logging to file and stdout (which is journaled under systemd)
# https://stackoverflow.com/questions/2990414/echo-that-outputs-to-stderr
function LOG {
	mkdir -p $(dirname $log)
	echo "$(date --iso-8601='seconds') $*" >> $log
	>&2 echo "$*"
}

# various queue configurations
# common buffer-limited queue (argument defines number of buffers, arg2 for leaky)
function bufferqueue {
	local result="queue max-size-buffers=$1 max-size-bytes=0 max-size-time=0 min-threshold-buffers=1 $2"
	echo $result
}
# common time-limited queue (arguments defines number of milliseconds of queueing, arg2 for leaky)
function timequeue {
	local result="queue max-size-buffers=0 max-size-bytes=0 max-size-time=$(($1 * 1000000)) min-threshold-buffers=1 $2"
	echo $result
}

if ${enable[debug]} ; then
    for k in ${!config[@]} ; do
        >&2 echo "config[$k]=${config[$k]}"
    done
    for k in ${!enable[@]} ; do
        >&2 echo "enable[$k]=${enable[$k]}"
    done
    for k in ${!udp[@]} ; do
        >&2 echo "udp[$k]=${udp[$k]}"
    done
    #exit 0
fi

# compute queue max-size-time parameter to avoid gstreamer
# "Impossible to configure latency" warnings/errors.  We calculate the amount
# of time for two frames at the desired frame rate (in nanoseconds).  Min 1ms.
fps=$(( ${config[fps]} ))
qmst=$(( ${config[video_latency]} ))
if [ $qmst -lt 1 ] ; then
	# user desires minimum latency
	if [ $fps -le 0 ] ; then qmst=1 ; else qmst=$(( (2000/$fps + 1) )) ; fi
fi
# when audio is enabled, there is a minimum amount of latency that has to be taken
# into effect.  This causes the audmux and flvmux ratios to be recalculated.
# failure to do this will result in RTMP streaming errors
if ${enable[audio]} && ${enable[rtmp]} && [ $qmst -le 1700 ] ; then
	LOG WARNING audio+video over RTMP requires 1.7 sec latency, $qmst ms may be too little
fi

# Common parts for gst spells
function flvmux {
	local result="$(timequeue $qmst leaky=upstream) ! mux.video flvmux streamable=true name=mux"
	if [ "${PLATFORM}" == "RPIX" ] ; then result="$result latency=$(($qmst * ${config[flvmux_ratio]} * 1000000))" ; fi
	echo $result
}
function rtpmux {
	local result="$(timequeue $qmst leaky=upstream) ! rtph264pay config-interval=10 pt=96 ! mux.sink_0 rtpmux name=mux"
	echo $result
}
function h264args {
	local result="\"video/x-h264,stream-format=(string)byte-stream,width=(int)$1,height=(int)$2,framerate=(fraction)$3\""
	if [ ! -z "${config[h264_profile]}" ] ; then result="$result,profile=(string)${config[h264_profile]}" ; fi
	result="$result ! h264parse"
	echo $result
}
function mjpgargs {
	local result="\"image/jpeg,width=(int)$1,height=(int)$2,framerate=(fraction)$3\""
	echo $result
}
function xrawargs {
	local result
	if [ -z "$4" ] ; then
		# format agnostic
		result="\"video/x-raw,width=(int)$1,height=(int)$2,framerate=(fraction)$3\""
	elif [ -z "$3" ] ; then
		# format+framerate agnostic
		result="\"video/x-raw,width=(int)$1,height=(int)$2\""
	elif [ -z "$2" -o -z "$1" ] ; then
		result="\"video/x-raw\""
	else
		result="\"video/x-raw,format=(string)$4,width=(int)$1,height=(int)$2,framerate=(fraction)$3\""
	fi
	echo $result
}
function overlay {
	local pad=25
	local width=$1
	local height=$2
	local fps=$3
	local name=$4
	shift 4
	if [ $height -gt 480 ] ; then pad=35 ; fi
	if [ $height -gt 720 ] ; then pad=55 ; fi
	local result="timeoverlay halignment=left valignment=top ypad=$(($pad * 2 + 25)) ! textoverlay halignment=left valignment=top ypad=$(($pad * 1 + 25)) name=$name text=\""$@"\" ! textoverlay halignment=left valignment=top ypad=25 text=\"${gst[version]}, $width x $height @$fps\""
	echo $result
}


# RTMP to ${URL}/${SKEY}
# NB: it seems that one of the keys to getting audio/video interleaving is to put
#     the flvmux into its own gstreamer thread and not making it part of the video pipeline
#     Also, latency needs to be specified
if ${enable[rtmp]} ; then
	if [ -z "${USERNAME}" -o -z "${KEY}" ] ; then
		gst[avsink]="$(flvmux) ! rtmpsink location=\"${config[url]}/${config[streamkey]} live=1 flashver=FME/3.0%20(compatible;%20FMSc%201.0)\""
	else
		gst[avsink]="$(flvmux) ! rtmpsink location=\"${config[url]}/${config[streamkey]}?username=${USERNAME}&password=${KEY}\""
	fi
elif ${enable[udp]} ; then
	gst[avsink]="$(rtpmux) ! udpsink ${udp[props]}"
else
	# must instantiate a mux that has sink templates of .sink_0 and .sink_1 (like for UDP)
	gst[avsink]="$(rtpmux) ! fakesink"
fi

# UDP to IP:PORT (separate video and audio ports)

# Sync with server
if ${enable[wan]} ; then
	response=false
	internet=/usr/local/bin/internet.py
	if [ ! -e $internet ] ; then internet=./internet.py ; fi
	if [ -z "${SERVER}" ] ; then _ARG="" && SERVER="internet" ; else _ARG="socket ${SERVER}" ; fi
	LOG SYNC with ${SERVER} using $internet
	while true ; do
		if x=$(python $internet ${_ARG}) ; then response=true ; break ; fi
		sleep 5
	done
	if ! $response ; then
		LOG NO response from ${SERVER}, pipeline may fail
		#gst[avsink]="$(flvmux) ! fakesink"
		#gst[avsink]="$(rtpmux) ! fakesink"
	fi
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
if [ -z "${gst[encoder]}" ] || [ -z "${gst[encoder_formats]}" ] ; then
    if ${enable[debug]} ; then
        for k in ${!encoder[@]} ; do
            >&2 echo "encoder[$k]=${encoder[$k]}"
        done
        for k in ${!gst[@]} ; do
            >&2 echo "gst[$k]=${gst[$k]}"
        done
    fi
    if ${enable[mjpg]} || ${enable[xraw]} ; then
        if ! ${enable[h264]} ; then
            LOG NO Encoder available - pipeline cannot be constructed
            exit 1
        fi
    fi
    # NB: encoder is not used for h264 source
    LOG NO Encoder available - pipeline may fail
    gst[encoder]="queue"
fi

# Determine which video scaler we will use
if ${enable[scale]} || ${enable[transform]} ; then
    for e in $(IFS=',';echo ${config[video_scalers]}) ; do
        LOG TRY $e
	    if gst-inspect-1.0 $e >> $log ; then
            LOG SELECT $e
            gst[videoscale]="$e"
            break
        fi
    done
    if [ "${gst[videoscale]}" == "videoscale" ] ; then
        LOG HW video scalers not available - using videoscale
    fi
fi

# video devices
# BEWARE: this is running in a separate shell, changes to the parent environment do not persist
function select_video_device {
	local d=$1
	local height
	local result=""
	if v4l2-ctl -d $d --list-formats > /tmp/video.$$ ; then
		LOG DEBUG consider $d
		>&2 cat /tmp/video.$$ >> $log
		if grep H264 /tmp/video.$$ > /dev/null && ${enable[h264]} ; then
			LOG H264=$d
			result="h264 $d false stop"
		elif grep MJPG /tmp/video.$$ > /dev/null && ${enable[mjpg]} ; then
			LOG MJPG=$d
			result="mjpg $d false stop"
		elif ! ${enable[xraw]} ; then
			LOG DEBUG skip $d because raw format is not enabled
		elif [ -z "${gst[encoder_formats]}" ] ; then
			LOG DEBUG skip $d because no encoder format is given
		else
			height=$(( ${config[height]} ))
			if ${enable[scale]} && [ ${height/.*} -gt 480 ] ; then height=360 ; fi
			( gst-launch-1.0 --gst-debug=v4l2src:5 v4l2src device=$d num-buffers=0 ! fakesink 2>&1 | sed -une '/caps of src/ s/[:;] /\n/gp' ) > /tmp/format.$$
			>&2 cat /tmp/format.$$ >> $log
			if grep -E ${gst[encoder_formats]} /tmp/format.$$ | grep -E $height > /dev/null ; then
				LOG XRAW=$d
				result="xraw $d false"
			elif grep -E YUY2 /tmp/format.$$ | grep -E $height > /dev/null ; then
				LOG XRAW=$d using videoconvert
				result="xraw $d true"
			else
				LOG DEBUG skip $d because no mode with image height of $height exists
			fi
		fi
	fi
	echo $result
}

declare -A dev
if [ -z "${config[video_device]}" ] ; then
	for d in /dev/video* ; do
		kdts=$(select_video_device $d)
		if [ -z "$kdts" ] ; then continue ; fi
		k="$(echo $kdts | cut -f1 -d' ')"
		d="$(echo $kdts | cut -f2 -d' ')"
		t="$(echo $kdts | cut -f3 -d' ')"
		s="$(echo $kdts | cut -f4 -d' ')"
		dev[$k]=$d
		enable[transform]=$t
		if [ "$s" == "stop" ] ; then break ; fi
		LOG DEBUG continue to consider other devices
	done
else
	# script desires to use a particular device path
	kdts=$(select_video_device ${config[video_device]})
	if [ -z "$kdts" ] ; then
		LOG DEBUG ${config[video_device]} not suitable
		exit 1
	fi
	k="$(echo $kdts | cut -f1 -d' ')"
	d="$(echo $kdts | cut -f2 -d' ')"
	t="$(echo $kdts | cut -f3 -d' ')"
	s="$(echo $kdts | cut -f4 -d' ')"
	dev[$k]=$d
	enable[transform]=$t
fi

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
		if grep S16LE /tmp/audio.$$ > /dev/null && ${enable[audio]} ; then
			echo "hw:${c},${d}" > ${LOGDIR}/gst.audio.dev.$$
		fi
	done
	if x=$(cat ${LOGDIR}/gst.audio.dev.$$) ; then
		if [ -z "$x" ] ; then
			LOG NO audio ${config[audio]} because /tmp/audio.$$ had no suitable capabilities
		else
			dev[audio]="$x"
			LOG SELECT "${dev[audio]} for ${config[audio]}"
		fi
	else
		LOG NO audio ${config[audio]} because ${LOGDIR}/gst.audio.dev.$$ was not read
	fi
	# Determine which audio encoder we will use
	for e in $(IFS=',';echo ${config[audio_encoders]}) ; do
		LOG TRY $e
		if gst-inspect-1.0 $e >> $log ; then
			LOG SELECT $e
			x=$(echo S16LE | grep -E ${encoder_formats[$e]})
			if [ -z "$x" ] ; then
				gst[audiopipeline]="alsasrc device=\"${dev[audio]}\" ! \"audio/x-raw,format=(string)S16LE,rate=(int)44100,channels=(int)1\" ! audioconvert ! ${encoder[$e]} ! aacparse ! $(timequeue $(($qmst * ${config[audmux_ratio]})))"
			else
				gst[audiopipeline]="alsasrc device=\"${dev[audio]}\" ! \"audio/x-raw,format=(string)S16LE,rate=(int)44100,channels=(int)1\" ! ${encoder[$e]} ! aacparse ! $(timequeue $(($qmst * ${config[audmux_ratio]})))"
			fi
			if ${enable[rtmp]} ; then
				gst[audiopipeline]="${gst[audiopipeline]} ! mux.audio"
			else
				gst[audiopipeline]="${gst[audiopipeline]} ! rtpmp4apay pt=96 ! mux.sink_1"
			fi
			break
		fi
	done
else
	gst[audiopipeline]=""
fi
if [ -z "${gst[audiopipeline]}" ] ; then
	LOG NO Audio encoder available
fi

# TODO: determine which video source we will use.  Options are v4l2src (default), uvch264src/uvch264mjpgdemux (if installed) and imxv4l2videosrc (imx6)
function videosource {
	local result="v4l2src device=$2 io-mode=mmap"
	if [ "$1" == "test" ] ; then result="videotestsrc is-live=true" ; fi
	echo $result
}

function transformer {
	local result="videoconvert ! ${gst[videoscale]}"
	if [[ ${gst[videoscale]} =~ .*imxipuvideotransform.* ]] ; then
		# https://github.com/Freescale/gstreamer-imx/issues/27
		#result="${gst[videoscale]} ! $(xrawargs $1 $2 $3 Y444) ! videoconvert ! $(xrawargs $1 $2 $3 $4)"
		result="${gst[videoscale]} ! $(xrawargs $1 $2 $3 $4)"
	fi
	echo $result
}

# Determine source pipeline in priority: H264->MJPG->XRAW->TEST
if [ ! -z "${dev[h264]}" ] ; then
	sourceinfo="H.264 ${dev[h264]} ${config[width]} ${config[height]} ${config[fps]}"
	gst[sourcepipeline]="$(videosource h264 ${dev[h264]})"
elif [ ! -z "${dev[mjpg]}" ] ; then
	sourceinfo="MJPG ${dev[mjpg]} ${config[width]} ${config[height]} ${config[fps]}"
	gst[sourcepipeline]="$(videosource mjpg ${dev[mjpg]}) ! $(mjpgargs ${config[width]} ${config[height]} ${config[fps]}) ! jpegdec ! $(xrawargs ${config[width]} ${config[height]} ${config[fps]} I420) ! ${gst[encoder]}"
elif [ ! -z "${dev[xraw]}" ] ; then
	height=$(( ${config[height]} ))
	if ${enable[scale]} && [ ${height/.*} -gt 480 ] ; then
		# for USB2.0, cameras cannot emit 1080p@30fps/720p@30fps so we pull 640x360@30fps and upscale
		sourceinfo="XRAW ${dev[xraw]} 640>${config[width]} 360>$height $fps"
		gst[sourcepipeline]="$(videosource xraw ${dev[xraw]}) ! $(xrawargs 640 360 ${config[fps]}) ! $(transformer ${config[width]} ${config[height]} ${config[fps]} I420) ! ${gst[encoder]}"
	elif ${enable[transform]} ; then
		sourceinfo="XRAW ${dev[xraw]} ${config[width]} ${config[height]} ${config[fps]} (transformed)"
		# NB: videoconvert should negotiate optimally so a camera that can emit I420 will be slightly more efficient
		gst[sourcepipeline]="$(videosource xraw ${dev[xraw]}) ! $(xrawargs ${config[width]} ${config[height]} ${config[fps]}) ! $(transformer ${config[width]} ${config[height]} ${config[fps]} I420) ! ${gst[encoder]}"
	else
		sourceinfo="XRAW ${dev[xraw]} ${config[width]} ${config[height]} ${config[fps]}"
		if [[ ${gst[encoder]} =~ .*v4l2h264enc.* ]] ; then
			# for v4l2h264enc use, do not give I420 format to v4l2src
			gst[sourcepipeline]="$(videosource xraw ${dev[xraw]}) ! $(xrawargs ${config[width]} ${config[height]} ${config[fps]}) ! ${gst[encoder]}"
		else
			gst[sourcepipeline]="$(videosource xraw ${dev[xraw]}) ! $(xrawargs ${config[width]} ${config[height]} ${config[fps]} I420) ! ${gst[encoder]}"
		fi
	fi
else
	sourceinfo="TEST ${config[width]} ${config[height]} ${config[fps]}"
	gst[sourcepipeline]="$(videosource test) ! $(xrawargs ${config[width]} ${config[height]} ${config[fps]} I420) ! $(overlay ${config[width]} ${config[height]} ${config[fps]} overlay ${gst[encoder]}) ! ${gst[encoder]}"
fi

# perform a speedtest before launching the pipeline if so configured
if ${enable[wan]} && ${enable[speedtest]} ; then
	LOG DEBUG speedtest...
	x=$(/usr/local/bin/speedtest-cli --no-download --single --json)
	echo $x | python -c "import json,sys ; x=json.load(sys.stdin) ; print(json.dumps(x,indent=2))" >> $log
	# analyze upload kbps
	ul=$(echo $x | python -c "import json,sys ; x=json.load(sys.stdin) ; print(int(x['upload']))")
	min_ul=$((${config[kbps]} * 1100))  # 10% over minimum bit rate, in bps
	message="measured: $(($ul / 1000)) kbps, required: $(($min_ul / 1000)) kbps"
	if [[ $ul -lt $min_ul ]] ; then
		message="$message *** BELOW MIN"
	fi
	LOG INFO $message
else
	message="Upload speedtest/wan not selected"
fi

# 2nd Sink for diagnostics/file recording
if ${enable[preview]} ; then
	gst[filesink]="$(timequeue $qmst leaky=downstream) ! $(overlay ${config[width]} ${config[height]} ${config[fps]} message $message) ! progressreport ! fpsdisplaysink sync=false video-sink=autovideosink"
else
	gst[filesink]="$(timequeue $qmst leaky=downstream) ! progressreport ! fakesink"
fi

# Cast gstreamer spell
# http://gstreamer-devel.966125.n4.nabble.com/Does-Gstreamer-has-a-element-that-can-split-one-stream-into-two-td966351.html
# https://serverfault.com/a/975753
# https://stackoverflow.com/questions/59085054/gstreamer-issue-with-adding-timeoverlay-on-rtmp-stream
echo "gst-launch-1.0 ${gst[sourcepipeline]} ! $(h264args ${config[width]} ${config[height]} ${config[fps]}) ! tee name=t t. ! ${gst[avsink]} t. ! ${gst[filesink]} ${gst[audiopipeline]}" > ${LOGDIR}/gst.cmd.$$
LOG BEGIN $sourceinfo ${config[kbps]} kbps ${LOGDIR}/gst.cmd.$$
cat ${LOGDIR}/gst.cmd.$$
if ${enable[debug]} ; then exit 0 ; fi
if ! source ${LOGDIR}/gst.cmd.$$ ; then
	exit 1
fi
