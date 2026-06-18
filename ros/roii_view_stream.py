#!/usr/bin/env python3
"""Capture the rviz 3rd-person viewport and publish it as a ROS Image so the
gateway can stream the REAL Autoware view (lidar cloud + lanelet map + ego +
trajectory) to the tablet -- much better than a synthetic road. ffmpeg x11grab
on :1 (shared with the container), cropped to the central viewport, scaled.
Run inside the container: python3 roii_view_stream.py
"""
import os, re, subprocess, time
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Image

DISPLAY = ":1"
OUT_W = 640
ENV = dict(os.environ, DISPLAY=DISPLAY)


def find_rviz():
    out = subprocess.run(["xdotool", "search", "--name", "RViz"],
                         capture_output=True, text=True, env=ENV).stdout.split()
    if not out:
        return None
    wid = out[-1]
    g = subprocess.run(["xdotool", "getwindowgeometry", "--shell", wid],
                       capture_output=True, text=True, env=ENV).stdout
    d = dict(re.findall(r"(\w+)=(-?\d+)", g))
    subprocess.run(["xdotool", "windowraise", wid], env=ENV)
    return int(d["X"]), int(d["Y"]), int(d["WIDTH"]), int(d["HEIGHT"])


def main():
    rclpy.init()
    n = Node("roii_view_stream")
    pub = n.create_publisher(Image, "/roii/view/image", 1)
    geo = None
    while geo is None and rclpy.ok():
        geo = find_rviz()
        if geo is None:
            print("waiting for rviz window...", flush=True); time.sleep(2)
    X, Y, W, H = geo
    # crop out the Displays panel (left), Views panel (right), toolbar (top),
    # status bar (bottom) -> just the 3D viewport.
    cx, cy = X + 478, Y + 128
    cw, ch = (W - 910) & ~1, (H - 235) & ~1
    oh = int(OUT_W * ch / cw); oh &= ~1
    cmd = ["ffmpeg", "-loglevel", "error", "-f", "x11grab", "-framerate", "8",
           "-video_size", f"{cw}x{ch}", "-i", f"{DISPLAY}.0+{cx},{cy}",
           "-vf", f"scale={OUT_W}:{oh}", "-pix_fmt", "bgr24", "-f", "rawvideo", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, env=ENV)
    fsize = OUT_W * oh * 3
    print(f"streaming rviz {cw}x{ch} -> {OUT_W}x{oh} @8fps -> /roii/view/image", flush=True)
    while rclpy.ok():
        buf = p.stdout.read(fsize)
        if not buf or len(buf) < fsize:
            break
        m = Image()
        m.header.stamp = n.get_clock().now().to_msg(); m.header.frame_id = "rviz"
        m.height = oh; m.width = OUT_W; m.encoding = "bgr8"
        m.is_bigendian = 0; m.step = OUT_W * 3; m.data = buf
        pub.publish(m)
    p.terminate()


if __name__ == "__main__":
    main()
