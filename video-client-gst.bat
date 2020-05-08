@echo off
@rem get gstreamer from https://gstreamer.freedesktop.org/documentation/installing/on-windows.html
@rem I used 'gstreamer-1.0-msvc-x86_64-1.15.90'
set PATH=%GSTREAMER_1_0_ROOT_X86_64%\bin;%PATH%
set GST_PLUGIN_PATH_1_0=%GSTREAMER_1_0_ROOT_X86_64%\lib\gstreamer-1.0
@rem defaults if when no arguments are given (I like arguments because it makes testing easier)
set DEFAULT_VIDEO_PORT=5600
set DEFAULT_AUDIO_PORT=0
set DEFAULT_UDP_IP=224.0.0.1
set DEFAULT_MCAST_IFACE=Wireless*
@rem These caps are obtained from the "udpsink0.GstPad:sink: caps =" line
@rem https://stackoverflow.com/questions/49958663/how-to-properly-escape-parentheses-in-windows-batch-file
set "VIDEO_CAPS=application/x-rtp,media=(string)video,clock-rate=(int)90000,encoding-name=(string)H264,payload=(int)96"
set "AUDIO_CAPS=application/x-rtp"

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
@rem https://stackoverflow.com/questions/761615/is-there-a-way-to-indicate-the-last-n-parameters-in-a-batch-file/761658#761658
@if "%4"=="" goto arg4default
shift
shift
shift
set MCAST_IFACE=%1
:arg4loop
shift
if [%1]==[] goto argEnd
set MCAST_IFACE=%MCAST_IFACE% %~1
goto arg4loop
:arg4default
set MCAST_IFACE=%DEFAULT_MCAST_IFACE%
:argEnd

@rem compute the source command with respect to the UDP address
@for /F "tokens=1 delims=." %%a in ("%UDP_IP%") do ( set OCTET=%%a )
@if /I "%OCTET%" GEQ "224 " (
	@if /I "%OCTET%" LEQ "239 " (
		@rem Multicast source semantics
		echo "Multicast"
		@rem set UDPSRC=udpsrc address=%UDP_IP% multicast-iface="%MCAST_IFACE%" auto-multicast=true
		set UDPSRC=udpsrc uri=udp://%UDP_IP%:%VIDEO_PORT%
	) else (
		@rem Unicast source semantics
		echo "Unicast greater than 239."
		set UDPSRC=udpsrc address=%UDP_IP%
	)
) else if "%OCTET%"=="" (
	@rem Agnostic source semantics
	echo "Agnostic"
	set UDPSRC=udpsrc
) else (
	@rem Unicast source semantics
	echo "Unicast less than 224."
	@rem set UDPSRC=udpsrc address=%UDP_IP%
	set UDPSRC=udpsrc uri=udp://%UDP_IP%:%VIDEO_PORT%
)

@rem launch different spells depending on the balance of video/audio port
@if /I "%VIDEO_PORT%" EQU "0" (
    @if /I "%AUDIO_PORT%" EQU "0" (
        @rem run test pattern generation to test installation
        @echo gst-launch-1.0 videotestsrc is-live=true ! "video/x-raw,format=(string)I420,width=(int)640,height=(int)360,framerate=30/1" ! videoconvert ! autovideosink
        gst-launch-1.0 videotestsrc is-live=true ! "video/x-raw,format=(string)I420,width=(int)640,height=(int)360,framerate=30/1" ! videoconvert ! autovideosink
    ) else (
        @rem audio only
        @echo gst-launch-1.0 %UDPSRC% port=%AUDIO_PORT% caps="%AUDIO_CAPS%" ! rtpmp4adepay ! "audio/mpeg,codec_data=(buffer)1290" ! queue ! decodebin ! audioconvert ! autoaudiosink
        gst-launch-1.0 %UDPSRC% port=%AUDIO_PORT% caps="%AUDIO_CAPS%" ! rtpmp4adepay ! "audio/mpeg,codec_data=(buffer)1290" ! queue ! decodebin ! audioconvert ! autoaudiosink
    )
) else if /I "%AUDIO_PORT%" EQU "0" (
    @rem video only
    @rem echo gst-launch-1.0 %UDPSRC% port=%VIDEO_PORT% caps="%VIDEO_CAPS%" ! rtph264depay ! h264parse ! queue ! decodebin ! progressreport ! autovideosink
    @rem gst-launch-1.0 %UDPSRC% port=%VIDEO_PORT% caps="%VIDEO_CAPS%" ! rtph264depay ! h264parse ! queue ! decodebin ! progressreport ! autovideosink
    @echo gst-launch-1.0 %UDPSRC% caps="%VIDEO_CAPS%" ! rtph264depay ! h264parse ! queue ! decodebin ! progressreport ! autovideosink
    gst-launch-1.0 %UDPSRC% caps="%VIDEO_CAPS%" ! rtph264depay ! h264parse ! queue ! decodebin ! progressreport ! autovideosink
) else if /I "%VIDEO_PORT%" EQU "%AUDIO_PORT%" (
    @rem video+audio using same port (flvmux)
    @echo gst-launch-1.0 %UDPSRC% port=%VIDEO_PORT% ! queue ! flvdemux name=mux mux.video ! "%VIDEO_CAPS%" ! rtph264depay ! h264parse ! queue ! decodebin ! autovideosink mux.audio ! "%AUDIO_CAPS%" ! rtpmp4adepay ! "audio/mpeg,codec_data=(buffer)1290" ! queue ! decodebin ! audioconvert ! autoaudiosink
    gst-launch-1.0 %UDPSRC% port=%VIDEO_PORT% ! queue ! flvdemux name=mux mux.video ! "%VIDEO_CAPS%" ! rtph264depay ! h264parse ! queue ! decodebin ! autovideosink mux.audio ! "%AUDIO_CAPS%" ! rtpmp4adepay ! "audio/mpeg,codec_data=(buffer)1290" ! queue ! decodebin ! audioconvert ! autoaudiosink
) else (
    @rem video+audio using separate ports no mux
    @echo gst-launch-1.0 %UDPSRC% port=%VIDEO_PORT% caps="%VIDEO_CAPS%" ! rtph264depay ! h264parse ! queue ! decodebin ! autovideosink udpsrc multicast-group=%UDP_IP% multicast-iface="%MCAST_IFACE%" auto-multicast=true port=%AUDIO_PORT% caps="%AUDIO_CAPS%" ! rtpmp4adepay ! "audio/mpeg,codec_data=(buffer)1290" ! queue ! decodebin ! audioconvert ! autoaudiosink
    gst-launch-1.0 %UDPSRC% port=%VIDEO_PORT% caps="%VIDEO_CAPS%" ! rtph264depay ! h264parse ! queue ! decodebin ! autovideosink udpsrc multicast-group=%UDP_IP% multicast-iface="%MCAST_IFACE%" auto-multicast=true port=%AUDIO_PORT% caps="%AUDIO_CAPS%" ! rtpmp4adepay ! "audio/mpeg,codec_data=(buffer)1290" ! queue ! decodebin ! audioconvert ! autoaudiosink
)