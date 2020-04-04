# camera-streamer
Research code to setup gstreamer video+audio pipelines on various systems

## Setup
Execute the following commands:
```
make dependencies
make install
make provision
```

You can then control the automatic operation of the script using `systemctl x video-stream` where x is {status,start,disable}.
You can adjust the parameters in the config file, `/etc/systemd/rtmp-env.conf` or the script itself `/usr/local/bin/video-stream.sh`.

### RPI 3,4
For Raspberry Pi Model 3 or Model 4, please ensure that you configure GPU memory to 256M to avoid issues with omxh264enc or avenc_h264_omx.  Your `/boot/config.txt` should have the line:
```
gpu_mem=256
```

## References
* [RidgeRun Wiki](https://developer.ridgerun.com/wiki/index.php/Digital_Zoom,_Pan_and_Tilt_using_Gstreamer_Daemon)

