import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_flutter/webview_flutter.dart';
import '../../models/autoware_state.dart';

/// Tesla-style 3D autopilot view (light/daytime). A metric Three.js scene with
/// the ego ROii model centred, the REAL lanelet road (from the gateway's lane
/// polylines, ego-relative — actual curves, not a synthetic straight road), the
/// live planned-path ribbon (Tesla blue), and CenterPoint vehicles as 3D models.
/// Everything is in metres (1 unit = 1 m); the road group is transformed so the
/// ego sits at the origin heading up.
class SurroundView3D extends StatefulWidget {
  final AutowareState s;
  final List<List<List<double>>> polys; // real lanelet road polylines (map frame)
  const SurroundView3D({super.key, required this.s, this.polys = const []});
  @override
  State<SurroundView3D> createState() => _SurroundView3DState();
}

class _SurroundView3DState extends State<SurroundView3D> {
  WebViewController? _wv;
  HttpServer? _server;
  bool _loaded = false;
  bool _roadSent = false;

  static const _html = r'''
<!DOCTYPE html><html><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0,user-scalable=no">
<style>*{margin:0;padding:0}body{background:#EEF2F7;overflow:hidden;touch-action:none}</style>
</head><body>
<script type="importmap">
{"imports":{
  "three":"https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.module.js",
  "three/addons/":"https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/"
}}
</script>
<script type="module">
import * as THREE from 'three';
import {OrbitControls} from 'three/addons/controls/OrbitControls.js';
import {GLTFLoader} from 'three/addons/loaders/GLTFLoader.js';

const S = 1.0;   // 1 scene unit = 1 metre
const scene = new THREE.Scene();
scene.background = new THREE.Color(0xEEF2F7);
scene.fog = new THREE.FogExp2(0xEEF2F7, 0.0055);

const camera = new THREE.PerspectiveCamera(50, innerWidth/innerHeight, 0.1, 600);
camera.position.set(0, 5.2, 11.5);
camera.lookAt(0, 0.8, -7);

const R = new THREE.WebGLRenderer({antialias:true});
R.setSize(innerWidth, innerHeight); R.setPixelRatio(Math.min(devicePixelRatio,2));
R.toneMapping = THREE.ACESFilmicToneMapping; R.toneMappingExposure = 1.12;
document.body.appendChild(R.domElement);

const ctrl = new OrbitControls(camera, R.domElement);
ctrl.enableDamping = true; ctrl.dampingFactor = 0.05;
ctrl.target.set(0, 0.8, -6);
ctrl.maxPolarAngle = Math.PI*0.47; ctrl.minPolarAngle = Math.PI*0.04;
ctrl.minDistance = 8; ctrl.maxDistance = 60; ctrl.enablePan = false;

scene.add(new THREE.HemisphereLight(0xffffff, 0xc8d2de, 1.2));
const sun = new THREE.DirectionalLight(0xffffff, 1.5); sun.position.set(-8,22,10); scene.add(sun);
scene.add(new THREE.AmbientLight(0xffffff, 0.35));

// ground
const gnd = new THREE.Mesh(new THREE.PlaneGeometry(2000,2000),
  new THREE.MeshStandardMaterial({color:0xDCE3EB, roughness:1}));
gnd.rotation.x=-Math.PI/2; gnd.position.y=-0.02; scene.add(gnd);

// Ego-relative world wrapper. The map frame is (east,north) = right-handed; placing it
// as (X=east, Z=north) flips handedness -> road/objects render LEFT-RIGHT MIRRORED.
// Negating X on this parent group un-mirrors road + objects + path together. The ego car
// model is kept OUT of this group (added straight to the scene) so it is not flipped.
const world = new THREE.Group(); world.scale.x = -1; scene.add(world);
// REAL road network (lanelet polylines, map frame) -> a group we move under the ego
const roadGroup = new THREE.Group(); world.add(roadGroup);
window.setRoad = function(polys){
  while(roadGroup.children.length) { const c=roadGroup.children.pop(); if(c.geometry)c.geometry.dispose(); roadGroup.remove(c); }
  let arr; try{ arr = typeof polys==='string'?JSON.parse(polys):polys; }catch(e){ return; }
  const pos=[];
  arr.forEach(poly=>{ for(let i=0;i+1<poly.length;i++){
    pos.push(poly[i][0]*S,0.03,poly[i][1]*S, poly[i+1][0]*S,0.03,poly[i+1][1]*S);
  }});
  if(!pos.length) return;
  const g=new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos,3));
  // crisp dark lane lines (visible on the light ground) + a faint wide underlay
  // for a road-surface feel.
  roadGroup.add(new THREE.LineSegments(g.clone(), new THREE.LineBasicMaterial({color:0x9AA6B6})));
  const top=new THREE.LineSegments(g, new THREE.LineBasicMaterial({color:0x4A5566}));
  top.position.y=0.01; roadGroup.add(top);
};

// ego car. A clean low-poly Tesla-ish car is shown immediately so the car is ALWAYS
// visible; if the GLB model loads it replaces the placeholder.
function makeEgoCar(){
  const m=new THREE.Group();
  const paint=new THREE.MeshStandardMaterial({color:0x2A3B5E,roughness:0.35,metalness:0.5});
  const glass=new THREE.MeshStandardMaterial({color:0x9fc7ff,roughness:0.1,metalness:0.2,transparent:true,opacity:0.85});
  const body=new THREE.Mesh(new THREE.BoxGeometry(1.95,0.62,4.6),paint); body.position.y=0.62; m.add(body);
  const lower=new THREE.Mesh(new THREE.BoxGeometry(2.0,0.42,4.5),new THREE.MeshStandardMaterial({color:0x11161f,roughness:0.8})); lower.position.y=0.34; m.add(lower);
  const cabin=new THREE.Mesh(new THREE.BoxGeometry(1.78,0.58,2.4),paint); cabin.position.set(0,1.12,-0.15); m.add(cabin);
  const win=new THREE.Mesh(new THREE.BoxGeometry(1.66,0.5,2.2),glass); win.position.set(0,1.13,-0.15); m.add(win);
  // wheels
  const wheelGeo=new THREE.CylinderGeometry(0.4,0.4,0.28,18);
  const wheelMat=new THREE.MeshStandardMaterial({color:0x0a0d12,roughness:0.7});
  [[-0.95,1.5],[0.95,1.5],[-0.95,-1.5],[0.95,-1.5]].forEach(([x,z])=>{
    const w=new THREE.Mesh(wheelGeo,wheelMat); w.rotation.z=Math.PI/2; w.position.set(x,0.4,z); m.add(w);
  });
  // headlights glow (front = -Z)
  const hl=new THREE.MeshStandardMaterial({color:0xffffff,emissive:0xfff1c0,emissiveIntensity:1.2});
  [[-0.6],[0.6]].forEach(([x])=>{const l=new THREE.Mesh(new THREE.BoxGeometry(0.5,0.16,0.1),hl); l.position.set(x,0.66,-2.3); m.add(l);});
  return m;
}
let ego = makeEgoCar(); scene.add(ego);
new GLTFLoader().load('__CAR_URL__', g=>{
  const model = g.scene;
  const box=new THREE.Box3().setFromObject(model), sz=box.getSize(new THREE.Vector3()), ctr=box.getCenter(new THREE.Vector3());
  const len=Math.max(sz.x,sz.z)||1, k=4.7/len;
  model.scale.setScalar(k);
  model.position.set(-ctr.x*k, -box.min.y*k+0.02, -ctr.z*k);
  // orient so the model's long axis points forward (-Z); flip if it loaded sideways
  model.rotation.y = (sz.x > sz.z) ? Math.PI/2 : Math.PI;
  if(ego) scene.remove(ego);
  ego = model; scene.add(ego);
}, undefined, e=>console.log('ego load err (keeping placeholder)', e));

const COL={car:0x2563EB,truck:0xD97706,bus:0xD97706,unknown:0x64748B};
function mat(t){return new THREE.MeshStandardMaterial({color:new THREE.Color(COL[t]||COL.unknown),roughness:0.5,metalness:0.1,transparent:true,opacity:0.9});}
function buildModel(t){
  const m=new THREE.Group(), M=mat(t);
  const glass=new THREE.MeshStandardMaterial({color:0x93c5fd,roughness:0.2,transparent:true,opacity:0.7});
  if(t==='truck'||t==='bus'){
    const L=t==='bus'?7.5:6.2;
    const body=new THREE.Mesh(new THREE.BoxGeometry(2.2,2.2,L),M); body.position.y=1.2; m.add(body);
    const cab=new THREE.Mesh(new THREE.BoxGeometry(2.0,0.5,1.4),glass); cab.position.set(0,1.7,L/2-0.9); m.add(cab);
  } else {
    const body=new THREE.Mesh(new THREE.BoxGeometry(1.9,0.6,4.4),M); body.position.y=0.55; m.add(body);
    const cab=new THREE.Mesh(new THREE.BoxGeometry(1.7,0.55,2.1),M); cab.position.set(0,1.05,-0.1); m.add(cab);
    const win=new THREE.Mesh(new THREE.BoxGeometry(1.6,0.45,1.9),glass); win.position.set(0,1.07,-0.1); m.add(win);
  }
  return m;
}

// Tesla-style traffic light: dark housing on a pole + a glowing bulb of the live colour.
const TLCOL={1:0xEF4444,2:0xF59E0B,3:0x22C55E};   // 1=red 2=amber 3=green
function buildLight(color){
  const m=new THREE.Group();
  const pole=new THREE.Mesh(new THREE.CylinderGeometry(0.12,0.12,5.2,8),
    new THREE.MeshStandardMaterial({color:0x4B5563,roughness:0.8}));
  pole.position.y=2.6; m.add(pole);
  const housing=new THREE.Mesh(new THREE.BoxGeometry(0.7,1.7,0.45),
    new THREE.MeshStandardMaterial({color:0x1F2937,roughness:0.7}));
  housing.position.y=5.3; m.add(housing);
  const c=new THREE.Color(TLCOL[color]||0x9AA6B6);
  // three sockets (dim) + one lit bulb matching the live colour (none lit if unknown)
  const ys=[5.65,5.3,4.95]; const lit=color===1?0:(color===2?1:(color===3?2:-1));
  ys.forEach((yy,i)=>{
    const on=i===lit;
    const b=new THREE.Mesh(new THREE.SphereGeometry(0.22,16,16),
      new THREE.MeshStandardMaterial({color:on?c:0x111827,
        emissive:on?c:0x000000, emissiveIntensity:on?1.4:0.0, roughness:0.4}));
    b.position.set(0,yy,0.26); m.add(b);
    if(on){
      const halo=new THREE.Mesh(new THREE.SphereGeometry(0.42,16,16),
        new THREE.MeshBasicMaterial({color:c,transparent:true,opacity:0.25}));
      halo.position.set(0,yy,0.26); m.add(halo);
    }
  });
  return m;
}

let dets=[], pathMesh=null, lights=[];
window.updateDrive = function(ex,ey,yawDeg,objs,traj,tls){
  const th=yawDeg*Math.PI/180, ct=Math.cos(th), st=Math.sin(th);
  // move the map under the ego: ego -> origin, heading -> -z
  roadGroup.rotation.y = Math.PI/2 + th;
  roadGroup.position.set(S*(ex*st-ey*ct), 0, S*(ex*ct+ey*st));
  // objects (metric ego-relative)
  dets.forEach(d=>{d.traverse(c=>{if(c.geometry)c.geometry.dispose()}); world.remove(d)}); dets.length=0;
  let oa; try{oa=typeof objs==='string'?JSON.parse(objs):objs;}catch(e){oa=[];}
  oa.forEach(o=>{ const m=buildModel(o.type); m.position.set(o.rgt*S,0,-o.fwd*S); m.rotation.y=o.h; world.add(m); dets.push(m); });
  // traffic lights (ego-relative; same world group so they un-mirror with the road)
  lights.forEach(d=>{d.traverse(c=>{if(c.geometry)c.geometry.dispose()}); world.remove(d)}); lights.length=0;
  let la; try{la=typeof tls==='string'?JSON.parse(tls):tls;}catch(e){la=[];}
  (la||[]).forEach(o=>{ const m=buildLight(o.color); m.position.set(o.rgt*S,0,-o.fwd*S); world.add(m); lights.push(m); });
  // planned-path ribbon (Tesla blue) from the real trajectory
  if(pathMesh){world.remove(pathMesh); if(pathMesh.geometry)pathMesh.geometry.dispose(); pathMesh=null;}
  let ta; try{ta=typeof traj==='string'?JSON.parse(traj):traj;}catch(e){ta=[];}
  if(ta && ta.length>1){
    const pts=ta.map(p=>new THREE.Vector3(p[0]*S,0.08,-p[1]*S));
    const curve=new THREE.CatmullRomCurve3(pts);
    const tube=new THREE.TubeGeometry(curve, Math.min(120,ta.length*2), 1.0, 6, false);
    pathMesh=new THREE.Mesh(tube, new THREE.MeshBasicMaterial({color:0x2F6BFF,transparent:true,opacity:0.45}));
    world.add(pathMesh);
  }
};

(function anim(){ requestAnimationFrame(anim); ctrl.update(); R.render(scene,camera); })();
addEventListener('resize',()=>{camera.aspect=innerWidth/innerHeight;camera.updateProjectionMatrix();R.setSize(innerWidth,innerHeight);});
</script>
</body></html>
''';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    var carUrl = 'https://hwkim3330.github.io/tabsla/models/lowpoly_car.glb';
    try {
      final bytes = (await rootBundle.load('lib/assets/lowpoly_car.glb')).buffer.asUint8List();
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen((req) async {
        req.response.headers
          ..set('Access-Control-Allow-Origin', '*')
          ..set('Content-Type', 'model/gltf-binary');
        req.response.add(bytes);
        await req.response.close();
      });
      carUrl = 'http://127.0.0.1:${_server!.port}/roii.glb';
    } catch (_) {}
    final wv = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFEEF2F7))
      ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) {
        setState(() => _loaded = true);
        _roadSent = false;
        _push();
      }))
      ..loadHtmlString(_html.replaceAll('__CAR_URL__', carUrl));
    setState(() => _wv = wv);
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  @override
  void didUpdateWidget(SurroundView3D old) {
    super.didUpdateWidget(old);
    if (_loaded) _push();
  }

  void _push() {
    if (_wv == null || !_loaded) return;
    final s = widget.s;
    // send the real road once it's available
    if (!_roadSent && widget.polys.isNotEmpty) {
      _roadSent = true;
      _wv!.runJavaScript('setRoad(${jsonEncode(widget.polys)})');
    }
    final yaw = s.yawDeg * math.pi / 180.0;
    final cy = math.cos(yaw), sy = math.sin(yaw);
    final objs = <Map<String, dynamic>>[];
    for (final o in s.objects) {
      final dx = o.x - s.x, dy = o.y - s.y;
      final fwd = dx * cy + dy * sy, rgt = -dx * sy + dy * cy;
      if (fwd < -6 || fwd > 75 || rgt.abs() > 22) continue;
      if (o.cls == 5 || o.cls == 6 || o.cls == 7) continue;   // no VRUs (false +)
      objs.add({'rgt': double.parse(rgt.toStringAsFixed(1)),
        'fwd': double.parse(fwd.toStringAsFixed(1)),
        'type': _type(o.cls, o.sx, o.sy),
        'h': -((o.yawDeg - s.yawDeg) * math.pi / 180.0)});
    }
    final traj = <List<double>>[];
    for (final p in s.trajPath) {
      final dx = p[0] - s.x, dy = p[1] - s.y;
      final fwd = dx * cy + dy * sy, rgt = -dx * sy + dy * cy;
      if (fwd < -3 || fwd > 90) continue;
      traj.add([double.parse(rgt.toStringAsFixed(1)), double.parse(fwd.toStringAsFixed(1))]);
    }
    final tls = <Map<String, dynamic>>[];
    for (final t in s.trafficLights) {
      final dx = t.x - s.x, dy = t.y - s.y;
      final fwd = dx * cy + dy * sy, rgt = -dx * sy + dy * cy;
      if (fwd < -10 || fwd > 90 || rgt.abs() > 30) continue;
      tls.add({'rgt': double.parse(rgt.toStringAsFixed(1)),
        'fwd': double.parse(fwd.toStringAsFixed(1)), 'color': t.color});
    }
    _wv!.runJavaScript(
        'updateDrive(${s.x.toStringAsFixed(2)},${s.y.toStringAsFixed(2)},'
        '${s.yawDeg.toStringAsFixed(1)},${jsonEncode(objs)},${jsonEncode(traj)},${jsonEncode(tls)})');
  }

  String _type(int cls, double sx, double sy) {
    if (cls == 2 || cls == 4) return 'truck';
    if (cls == 3) return 'bus';
    final len = math.max(sx, sy);
    if (len >= 9.0) return 'bus';
    if (len >= 6.0) return 'truck';
    return 'car';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFEEF2F7),
      child: Stack(children: [
        if (_wv != null) Positioned.fill(child: WebViewWidget(controller: _wv!)),
        if (_wv == null || !_loaded)
          const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2563EB))),
      ]),
    );
  }
}
