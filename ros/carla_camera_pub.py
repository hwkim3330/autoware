import numpy as np, rclpy, time
from rclpy.node import Node
from sensor_msgs.msg import Image, CameraInfo
import carla

rclpy.init(); n=Node("carla_camera_pub")
pub=n.create_publisher(Image,"/sensing/camera/camera0/image_rect_color",1)
pci=n.create_publisher(CameraInfo,"/sensing/camera/camera0/camera_info",1)
c=carla.Client("localhost",2000); c.set_timeout(10.0); w=c.get_world()
try: w.wait_for_tick(3.0)
except Exception: pass
ego=next((a for a in w.get_actors().filter("vehicle.*") if a.attributes.get("role_name")=="ego_vehicle"),None)
if ego is None: print("NO EGO",flush=True); raise SystemExit
W,H=640,360
bp=w.get_blueprint_library().find("sensor.camera.rgb")
# 640x360 @5Hz: lighter on CARLA's render tick so the 4-LiDAR scan rate stays
# high (960x540@10Hz roughly halved the concat rate -> shaky NDT).
bp.set_attribute("image_size_x",str(W)); bp.set_attribute("image_size_y",str(H)); bp.set_attribute("fov","90"); bp.set_attribute("sensor_tick","0.2")
cam=w.spawn_actor(bp, carla.Transform(carla.Location(x=1.5,z=1.6)), attach_to=ego)
print("camera attached id",cam.id,flush=True)
ci=CameraInfo(); ci.width=W; ci.height=H; ci.header.frame_id="camera0/camera_link"
fx=W/(2*np.tan(np.radians(90)/2))
ci.k=[fx,0.0,W/2.0, 0.0,fx,H/2.0, 0.0,0.0,1.0]
ci.p=[fx,0.0,W/2.0,0.0, 0.0,fx,H/2.0,0.0, 0.0,0.0,1.0,0.0]
ci.distortion_model="plumb_bob"; ci.d=[0.0]*5
cnt=[0]
def cb(img):
    a=np.frombuffer(img.raw_data,dtype=np.uint8).reshape((img.height,img.width,4))  # BGRA
    bgr=a[:,:,:3].copy()
    m=Image(); m.header.stamp=n.get_clock().now().to_msg(); m.header.frame_id="camera0/camera_link"
    m.height=img.height; m.width=img.width; m.encoding="bgr8"; m.is_bigendian=0; m.step=img.width*3
    m.data=bgr.tobytes(); pub.publish(m)
    ci.header.stamp=m.header.stamp; pci.publish(ci); cnt[0]+=1
cam.listen(cb)
print("publishing /sensing/camera/camera0/image_rect_color",flush=True)
import threading
threading.Thread(target=lambda:rclpy.spin(n),daemon=True).start()
while True:
    time.sleep(5); print("frames published:",cnt[0],flush=True)
