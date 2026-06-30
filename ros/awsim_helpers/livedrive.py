import rclpy,time,math
from rclpy.node import Node
from autoware_adapi_v1_msgs.srv import SetRoutePoints,ClearRoute,ChangeOperationMode
from nav_msgs.msg import Odometry
rclpy.init(); n=Node("ld"); g={}
n.create_subscription(Odometry,"/localization/kinematic_state",lambda m:g.__setitem__("o",m),10)
t=time.time()
while time.time()-t<6 and "o" not in g: rclpy.spin_once(n,timeout_sec=0.3)
o=g["o"].pose.pose; ex,ey=o.position.x,o.position.y; q=o.orientation; yaw=2*math.atan2(q.z,q.w)
def call(c,r):
  if not c.wait_for_service(timeout_sec=6): return None
  f=c.call_async(r); rclpy.spin_until_future_complete(n,f,timeout_sec=12); return f.result()
ok=False
for d in [70,55,40]:
  call(n.create_client(ClearRoute,"/api/routing/clear_route"),ClearRoute.Request()); time.sleep(0.8)
  gx,gy=ex+d*math.cos(yaw),ey+d*math.sin(yaw)
  req=SetRoutePoints.Request(); req.header.frame_id="map"
  req.goal.position.x=gx; req.goal.position.y=gy; req.goal.position.z=43.1
  req.goal.orientation.z=math.sin(yaw/2); req.goal.orientation.w=math.cos(yaw/2)
  r=call(n.create_client(SetRoutePoints,"/api/routing/set_route_points"),req)
  if r and r.status.success: print("route d=%dm SET"%d); ok=True; break
if not ok: print("no route"); raise SystemExit
print("waiting 16s for trajectory/diag readiness...")
t=time.time()
while time.time()-t<16: rclpy.spin_once(n,timeout_sec=0.4)
r=call(n.create_client(ChangeOperationMode,"/api/operation_mode/change_to_autonomous"),ChangeOperationMode.Request())
print("engage:", "OK" if (r and r.status.success) else "FAIL")
first=(ex,ey); maxs=0; lp=-3
t=time.time()
while time.time()-t<32:
  rclpy.spin_once(n,timeout_sec=0.3)
  o=g["o"].pose.pose; sp=g["o"].twist.twist.linear.x*3.6; maxs=max(maxs,sp); el=time.time()-t
  if el-lp>=4:
    lp=el; mv=math.hypot(o.position.x-first[0],o.position.y-first[1])
    print("t=%2.0fs speed=%5.1f km/h moved=%4.1fm"%(el,sp,mv))
mv=math.hypot(o.position.x-first[0],o.position.y-first[1])
print("=== DROVE %.1fm, max %.1f km/h ==="%(mv,maxs))
