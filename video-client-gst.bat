@echo off
@rem get gstreamer from https://gstreamer.freedesktop.org/documentation/installing/on-windows.html
@rem I used 'gstreamer-1.0-msvc-x86_64-1.15.90'
set PATH=%GSTREAMER_1_0_ROOT_X86_64%\bin;%PATH%
set GST_PLUGIN_PATH_1_0=%GSTREAMER_1_0_ROOT_X86_64%\lib\gstreamer-1.0
@rem defaults if when no arguments are given (I like arguments because it makes testing easier)
set DEFAULT_VIDEO_PORT=5600
set DEFAULT_AUDIO_PORT=0
set DEFAULT_UDP_IP=224.1.1.1
set DEFAULT_VIDEO_ENCD=H264
set DEFAULT_MCAST_IFACE=*Wi-Fi
@rem These caps are obtained from the "udpsink0.GstPad:sink: caps =" line
@rem https://stackoverflow.com/questions/49958663/how-to-properly-escape-parentheses-in-windows-batch-file
set "AUDIO_CAPS=application/x-rtp"
set "VIDEO_CAPS=application/x-rtp,media=(string)video,clock-rate=(int)90000,payload=(int)96,encoding-name=(string)"
@rem Audio buffer is based on the AAC encoder channels: 1208=1 channel, 1210=2 channel
@rem https://stackoverflow.com/questions/7760545/escape-double-quotes-in-parameter
set "AUDIO_DEPAY=rtpmp4adepay ! ^"audio/mpeg,codec_data=1208^" ! queue"
set "VIDEO_DEPAY=rtph264depay ! h264parse ! queue"


@rem accept command line arguments for Video/Audio Port, IP address
@rem https://stackoverflow.com/questions/42283939/set-variable-inside-if-statement-windows-batch-file
:arg1
@if "%1"=="" goto arg1default
set VIDEO_PORT=%1
goto arg2
:arg1default
set VIDEO_PORT=%DEFAULT_VIDEO_PORT%
:arg2
@if "%2"=="" goto arg2default
set AUDIO_PORT=%2
goto arg3
:arg2default
set AUDIO_PORT=%DEFAULT_AUDIO_PORT%
:arg3
@if "%3"=="" goto arg3default
set UDP_IP=%3
goto arg4
:arg3default
set UDP_IP=%DEFAULT_UDP_IP%
:arg4
@if "%4"=="" goto arg4default
set VIDEO_ENCD=%4
goto arg5
:arg4default
set VIDEO_ENCD=%DEFAULT_VIDEO_ENCD%
:arg5
@rem https://stackoverflow.com/questions/761615/is-there-a-way-to-indicate-the-last-n-parameters-in-a-batch-file/761658#761658
@if "%5"=="" goto arg5default
shift
shift
shift
shift
set MCAST_IFACE=%1
:arg5loop
shift
if [%1]==[] goto argEnd
set MCAST_IFACE=%MCAST_IFACE% %~1
goto arg5loop
:arg5default
set MCAST_IFACE=%DEFAULT_MCAST_IFACE%
:argEnd

@rem compute the source command with respect to the UDP address
@for /F "tokens=1 delims=." %%a in ("%UDP_IP%") do ( set OCTET=%%a )
@if /I "%OCTET%" GEQ "224 " (
	@if /I "%OCTET%" LEQ "239 " (
		echo "Multicast"
		@rem set UDPSRC=udpsrc address=%UDP_IP% multicast-iface="%MCAST_IFACE%" auto-multicast=true
		set UDPSRC=udpsrc uri=udp://%UDP_IP%:
	) else (
		echo "Unicast greater than 239."
		set UDPSRC=udpsrc address=%UDP_IP% port=
	)
) else if "%OCTET%"=="" (
	echo "Agnostic"
	set UDPSRC=udpsrc port=
) else (
	echo "Unicast less than 224."
	@rem set UDPSRC=udpsrc address=%UDP_IP%
	set UDPSRC=udpsrc uri=udp://%UDP_IP%:
)

@rem launch different spells depending on the balance of video/audio port
@if /I "%VIDEO_PORT%" EQU "0" (
    @if /I "%AUDIO_PORT%" EQU "0" (
        echo "Test Pattern"
        @echo gst-launch-1.0 videotestsrc is-live=true ! "video/x-raw,format=(string)I420,width=(int)640,height=(int)360,framerate=30/1" ! videoconvert ! autovideosink
        gst-launch-1.0 videotestsrc is-live=true ! "video/x-raw,format=(string)I420,width=(int)640,height=(int)360,framerate=30/1" ! videoconvert ! autovideosink
    ) else (
        echo "Audio Only"
        @echo gst-launch-1.0 %UDPSRC%%AUDIO_PORT% caps="%AUDIO_CAPS%" ! %AUDIO_DEPAY% ! decodebin ! audioconvert ! directsoundsink sync=false
        gst-launch-1.0 %UDPSRC%%AUDIO_PORT% caps="%AUDIO_CAPS%" ! %AUDIO_DEPAY% ! decodebin ! audioconvert ! directsoundsink sync=false
    )
) else if /I "%AUDIO_PORT%" EQU "0" (
    echo "Video Only"
    @echo gst-launch-1.0 %UDPSRC%%VIDEO_PORT% caps="%VIDEO_CAPS%%VIDEO_ENCD%" ! %VIDEO_DEPAY% ! decodebin ! progressreport ! autovideosink
    gst-launch-1.0 %UDPSRC%%VIDEO_PORT% caps="%VIDEO_CAPS%%VIDEO_ENCD%" ! %VIDEO_DEPAY% ! decodebin ! progressreport ! autovideosink
) else if /I "%VIDEO_PORT%" EQU "%AUDIO_PORT%" (
    echo "Video+Audio using same port (flvmux)"
    @echo gst-launch-1.0 %UDPSRC%%VIDEO_PORT% ! queue ! flvdemux name=mux mux.video ! "%VIDEO_CAPS%%VIDEO_ENCD%" ! %VIDEO_DEPAY% ! decodebin ! autovideosink mux.audio ! "%AUDIO_CAPS%" ! %AUDIO_DEPAY% ! decodebin ! audioconvert ! directsoundsink sync=false
    gst-launch-1.0 %UDPSRC%%VIDEO_PORT% ! queue ! flvdemux name=mux mux.video ! "%VIDEO_CAPS%%VIDEO_ENCD%" ! %VIDEO_DEPAY% ! decodebin ! autovideosink mux.audio ! "%AUDIO_CAPS%" ! %AUDIO_DEPAY% ! decodebin ! audioconvert ! directsoundsink sync=false
) else (
    echo "Video+Audio using separate ports no mux"
    @echo gst-launch-1.0 %UDPSRC%%VIDEO_PORT% caps="%VIDEO_CAPS%%VIDEO_ENCD%" ! %VIDEO_DEPAY% ! decodebin ! autovideosink udpsrc %UDPSRC%%AUDIO_PORT% caps="%AUDIO_CAPS%" ! %AUDIO_DEPAY% ! decodebin ! audioconvert ! directsoundsink sync=false
    gst-launch-1.0 %UDPSRC%%VIDEO_PORT% caps="%VIDEO_CAPS%%VIDEO_ENCD%" ! %VIDEO_DEPAY% ! decodebin ! autovideosink udpsrc %UDPSRC%%AUDIO_PORT% caps="%AUDIO_CAPS%" ! %AUDIO_DEPAY% ! decodebin ! audioconvert ! directsoundsink sync=false
)
