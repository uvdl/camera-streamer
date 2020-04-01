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

## References
* [RidgeRun Wiki](https://developer.ridgerun.com/wiki/index.php/Digital_Zoom,_Pan_and_Tilt_using_Gstreamer_Daemon)

