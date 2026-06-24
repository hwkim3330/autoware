import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../models/autoware_state.dart';

/// Tesla-style top-down 2D map. Draws the lane network, the planned trajectory,
/// the ego car (oriented by yaw), and a tapped destination pin. Tapping the map
/// reports the world (Autoware-frame) coordinate via [onTapWorld] -> the screen
/// turns that into {cmd: goto, x, y} for the gateway (tap-to-go autonomy).
///
/// Frame convention: Autoware map frame (x right, y up, metres). Screen y is
/// flipped. The view follows the ego and supports pinch-zoom + drag-pan.
class MapView extends StatefulWidget {
  final AutowareState s;
  final List<List<double>> lanes; // [[x,y],...] map frame, downsampled
  final List<List<List<double>>> polys; // per-lanelet polylines (roads)
  final void Function(double x, double y) onTapWorld;
  final bool light; // Tesla light/white nav theme
  const MapView({super.key, required this.s, required this.lanes,
      this.polys = const [], required this.onTapWorld, this.light = false});

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  final List<Offset> _trail = [];   // driven path (map frame)
  double _scale = 7.0;          // pixels per metre (Tesla-tight follow-cam)
  double _scaleStart = 7.0;
  Offset _pan = Offset.zero;     // manual pan offset (px), reset on follow
  bool _follow = true;
  bool _headingUp = true;        // Tesla default: heading-up while following
  Offset? _dest;                 // destination pin (world coords)

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      final ego = Offset(widget.s.x, widget.s.y);
      // record driven trail (every ~2 m, capped). A big jump (>15 m) means a
      // teleport / respawn / replay-loop restart -> clear the trail so it
      // doesn't draw a long line across the map.
      if (_trail.isNotEmpty && (_trail.last - ego).distance > 15.0) {
        _trail.clear();
      }
      if (widget.s.speedKmh.abs() > 0.5 &&
          (_trail.isEmpty || (_trail.last - ego).distance > 2.0)) {
        _trail.add(ego);
        if (_trail.length > 600) _trail.removeAt(0);
      }
      // Tesla-style: while following heading-up, sit the ego in the lower third
      // so most of the screen shows the road AHEAD; free-pan keeps it centered.
      final egoY = (_follow && _headingUp) ? size.height * 0.62 : size.height / 2;
      final center = Offset(size.width / 2, egoY) + (_follow ? Offset.zero : _pan);
      // heading-up: rotate the (north-up) screen frame so the ego heading
      // points up; only while following (free pan is always north-up).
      final yaw = widget.s.yawDeg * math.pi / 180.0;
      final rot = (_headingUp && _follow) ? (yaw - math.pi / 2) : 0.0;
      final cosR = math.cos(rot), sinR = math.sin(rot);

      Offset worldToScreen(double wx, double wy) {
        final dx = (wx - ego.dx) * _scale;
        final dy = -(wy - ego.dy) * _scale;
        return Offset(center.dx + dx * cosR - dy * sinR,
            center.dy + dx * sinR + dy * cosR);
      }

      Offset screenToWorld(Offset p) {
        final sx = p.dx - center.dx, sy = p.dy - center.dy;
        final dx = sx * cosR + sy * sinR;     // inverse rotation
        final dy = -sx * sinR + sy * cosR;
        return Offset(ego.dx + dx / _scale, ego.dy - dy / _scale);
      }

      return GestureDetector(
        onScaleStart: (d) => _scaleStart = _scale,
        onScaleUpdate: (d) {
          setState(() {
            if (d.scale != 1.0) {
              _scale = (_scaleStart * d.scale).clamp(0.6, 30.0);
            } else {
              _follow = false;
              _pan += d.focalPointDelta;
            }
          });
        },
        onTapUp: (d) {
          final w = screenToWorld(d.localPosition);
          setState(() => _dest = w);
          widget.onTapWorld(w.dx, w.dy);
        },
        child: Stack(children: [
          CustomPaint(
            size: size,
            painter: _MapPainter(
              s: widget.s, lanes: widget.lanes, polys: widget.polys,
              scale: _scale, w2s: worldToScreen, dest: _dest, rot: rot,
              trail: List.of(_trail), light: widget.light,
            ),
          ),
          // Tesla map control stack (right edge): recenter + zoom in/out
          Positioned(
            right: 12, top: 12,
            child: Column(children: [
              _RoundBtn(
                icon: !_follow
                    ? Icons.location_searching
                    : (_headingUp ? Icons.navigation : Icons.explore),
                active: _follow,
                onTap: () => setState(() {
                  if (!_follow) { _follow = true; _pan = Offset.zero; _scale = 7.0; }
                  else { _headingUp = !_headingUp; }
                }),
              ),
              const SizedBox(height: 10),
              _RoundBtn(icon: Icons.add, active: false,
                  onTap: () => setState(() => _scale = (_scale * 1.4).clamp(0.6, 30.0))),
              const SizedBox(height: 10),
              _RoundBtn(icon: Icons.remove, active: false,
                  onTap: () => setState(() => _scale = (_scale / 1.4).clamp(0.6, 30.0))),
            ]),
          ),
          // Tesla ETA / route card (bottom-center) while navigating
          if (widget.s.trajPath.length > 1)
            Positioned(
              left: 0, right: 0, bottom: 14,
              child: IgnorePointer(child: Center(child: _EtaCard(s: widget.s))),
            ),
        ]),
      );
    });
  }
}

/// Tesla navigation card: remaining distance + ETA from the live trajectory.
class _EtaCard extends StatelessWidget {
  final AutowareState s;
  const _EtaCard({required this.s});
  @override
  Widget build(BuildContext context) {
    double dist = 0;
    final tp = s.trajPath;
    for (int i = 1; i < tp.length; i++) {
      dist += math.sqrt(math.pow(tp[i][0] - tp[i - 1][0], 2) +
          math.pow(tp[i][1] - tp[i - 1][1], 2));
    }
    final v = s.speedKmh.abs() > 1 ? s.speedKmh.abs() : 15.0; // km/h
    final mins = (dist / 1000) / v * 60;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xF21B1B1B),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.navigation, color: Color(0xFF3E6AE1), size: 18),
        const SizedBox(width: 10),
        Text(
          dist >= 1000
              ? '${(dist / 1000).toStringAsFixed(1)} km'
              : '${dist.toStringAsFixed(0)} m',
          style: const TextStyle(
              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 12),
        Text('${mins < 1 ? '<1' : mins.toStringAsFixed(0)} min',
            style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 14)),
      ]),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  final IconData icon; final bool active; final VoidCallback onTap;
  const _RoundBtn({required this.icon, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) => Material(
        color: active ? const Color(0xFF1E88E5) : const Color(0xCC1B2433),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(10),
              child: Icon(icon, color: Colors.white, size: 20)),
        ),
      );
}

class _MapPainter extends CustomPainter {
  final AutowareState s;
  final List<List<double>> lanes;
  final List<List<List<double>>> polys;
  final double scale;
  final Offset Function(double, double) w2s;
  final Offset? dest;
  final double rot;
  final List<Offset> trail;
  final bool light;
  _MapPainter({required this.s, required this.lanes, required this.polys,
      required this.scale, required this.w2s, required this.dest,
      required this.rot, this.trail = const [], this.light = false});

  @override
  void paint(Canvas c, Size size) {
    // Tesla dark navigation theme: charcoal canvas, grey road network,
    // Tesla-blue route line, red destination pin, arrow-style ego marker.
    final bg = Paint()..color = light ? const Color(0xFFE9EEF4) : const Color(0xFF171717);
    c.drawRect(Offset.zero & size, bg);

    // --- road network: stroke each lanelet polyline as a road (Tesla look);
    //     fall back to dots if the gateway only sent points.
    final cull = Rect.fromLTRB(-60, -60, size.width + 60, size.height + 60);
    if (polys.isNotEmpty) {
      final roadPaint = Paint()
        ..color = light ? const Color(0xFFFFFFFF) : const Color(0xFF35373C)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (3.5 * scale).clamp(2.0, 26.0)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final centerPaint = Paint()
        ..color = light ? const Color(0xFFCBD5E1) : const Color(0xFF515459)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      for (final poly in polys) {
        if (poly.length < 2) continue;
        final pts = [for (final p in poly) w2s(p[0], p[1])];
        if (!pts.any(cull.contains)) continue;
        final path = Path()..moveTo(pts[0].dx, pts[0].dy);
        for (var i = 1; i < pts.length; i++) {
          path.lineTo(pts[i].dx, pts[i].dy);
        }
        c.drawPath(path, roadPaint);
        if (scale > 3) c.drawPath(path, centerPaint);
      }
    } else {
      final lanePaint = Paint()..color = light ? const Color(0xFFC2CCD8) : const Color(0xFF46484D);
      final r = (scale * 0.45).clamp(1.2, 4.0);
      for (final p in lanes) {
        final sp = w2s(p[0], p[1]);
        if (cull.contains(sp)) c.drawCircle(sp, r, lanePaint);
      }
    }

    // --- driven trail (faint teal breadcrumb) ---
    if (trail.length > 1) {
      final tp = Path();
      bool first = true;
      for (final w in trail) {
        final sp = w2s(w.dx, w.dy);
        if (first) { tp.moveTo(sp.dx, sp.dy); first = false; }
        else { tp.lineTo(sp.dx, sp.dy); }
      }
      c.drawPath(tp, Paint()
        ..color = const Color(0x5526C6DA)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round);
    }

    // --- FULL route to the destination (faint wide blue under the live path) ---
    if (s.routePath.length > 1) {
      final rp = Path();
      bool f0 = true;
      for (final p in s.routePath) {
        final sp = w2s(p[0], p[1]);
        if (f0) { rp.moveTo(sp.dx, sp.dy); f0 = false; }
        else { rp.lineTo(sp.dx, sp.dy); }
      }
      final rw = (2.4 * scale).clamp(6.0, 30.0);
      c.drawPath(rp, Paint()
        ..color = const Color(0x3344A0FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = rw
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round);
      // destination flag at the route end
      final end = s.routePath.last;
      final esp = w2s(end[0], end[1]);
      c.drawCircle(esp, 7, Paint()..color = const Color(0xFF4E86FF));
      c.drawCircle(esp, 7, Paint()
        ..color = Colors.white ..style = PaintingStyle.stroke ..strokeWidth = 2);
    }

    // --- planned route (Tesla blue, flat) ---
    if (s.trajPath.length > 1) {
      final path = Path();
      bool first = true;
      for (final p in s.trajPath) {
        final sp = w2s(p[0], p[1]);
        if (first) { path.moveTo(sp.dx, sp.dy); first = false; }
        else { path.lineTo(sp.dx, sp.dy); }
      }
      final w = (1.6 * scale).clamp(5.0, 22.0);   // ~lane-width ribbon
      c.drawPath(path, Paint()                      // outer glow
        ..color = const Color(0x553E6AE1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w + 8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      c.drawPath(path, Paint()                      // core ribbon
        ..color = const Color(0xFF4E86FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round);
      c.drawPath(path, Paint()                      // bright centerline
        ..color = const Color(0xCCBFD4FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (w * 0.28).clamp(1.0, 5.0)
        ..strokeCap = StrokeCap.round);
    }

    // --- destination pin (red, Tesla nav style) ---
    if (dest != null) {
      final dp = w2s(dest!.dx, dest!.dy);
      const pinC = Color(0xFFD32F2F);
      c.drawCircle(dp - const Offset(0, 12), 8, Paint()..color = pinC);
      final stem = Path()
        ..moveTo(dp.dx - 5, dp.dy - 9)..lineTo(dp.dx + 5, dp.dy - 9)
        ..lineTo(dp.dx, dp.dy)..close();
      c.drawPath(stem, Paint()..color = pinC);
      c.drawCircle(dp - const Offset(0, 12), 3, Paint()..color = Colors.white);
    }

    // --- surround objects (CenterPoint): Tesla-style cars + pedestrians ---
    for (final o in s.objects) {
      final op = w2s(o.x, o.y);
      if (!cull.contains(op)) continue;
      final oyaw = o.yawDeg * math.pi / 180.0;
      c.save();
      c.translate(op.dx, op.dy);
      c.rotate(-oyaw + math.pi / 2 + rot);
      if (o.isPedestrian) {
        // glowing dot — a person near the car (Tesla highlights pedestrians)
        final r = (0.55 * scale).clamp(4.0, 14.0);
        c.drawCircle(Offset.zero, r + 4, Paint()
          ..color = const Color(0x6600E5FF)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
        c.drawCircle(Offset.zero, r, Paint()..color = const Color(0xFF12E0F2));
        c.drawCircle(Offset.zero, r, Paint()
          ..color = Colors.white ..style = PaintingStyle.stroke ..strokeWidth = 1.6);
      } else {
        // vehicle / cyclist / unknown — oriented rounded box sized in metres
        final isCycle = o.isCycle;
        final fill = o.cls == 0
            ? const Color(0xFF55585F)                 // unknown: dim grey
            : (isCycle ? const Color(0xFFFFB300) : const Color(0xFF8B9099));
        final l = (math.max(o.sx, isCycle ? 1.5 : 3.5) * scale).clamp(10.0, 150.0);
        final w = (math.max(o.sy, isCycle ? 0.7 : 1.7) * scale).clamp(6.0, 70.0);
        final rr = RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset.zero, width: w, height: l),
            Radius.circular((w * 0.28).clamp(2.0, 10.0)));
        c.drawRRect(rr.shift(const Offset(0, 2)), Paint()
          ..color = Colors.black.withValues(alpha: 0.4)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
        c.drawRRect(rr, Paint()..color = fill);
        c.drawRRect(rr, Paint()
          ..color = Colors.white.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke ..strokeWidth = 1.4);
        // heading nub so direction is readable when zoomed in
        if (l > 22) {
          c.drawRRect(
              RRect.fromRectAndRadius(
                  Rect.fromCenter(center: Offset(0, -l * 0.32), width: w * 0.7, height: l * 0.18),
                  const Radius.circular(2)),
              Paint()..color = Colors.white.withValues(alpha: 0.85));
        }
      }
      c.restore();
    }

    // --- ego: Tesla-style car silhouette (scales with zoom, oriented by yaw) ---
    final ep = w2s(s.x, s.y);
    final yaw = s.yawDeg * math.pi / 180.0;
    final autop = s.isAutonomous;
    final accent = autop ? const Color(0xFF3E6AE1) : const Color(0xFFE8E8EA);
    c.save();
    c.translate(ep.dx, ep.dy);
    // world +x is screen +x, world +y is screen -y; art points up (-y) = forward
    c.rotate(-yaw + math.pi / 2 + rot);
    // autopilot glow halo
    if (autop) {
      c.drawCircle(Offset.zero, 26,
          Paint()..color = const Color(0x333E6AE1)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
    }
    // car body sized in metres so it sits naturally on the road
    final L = (4.9 * scale).clamp(16.0, 130.0);   // ROii length 4.9 m
    final W = (2.1 * scale).clamp(8.0, 58.0);      // width 2.1 m
    final hl = L / 2, hw = W / 2;
    final body = Path()
      ..moveTo(0, -hl)                                   // nose
      ..cubicTo(hw, -hl, hw, -hl * 0.45, hw, -hl * 0.25)
      ..lineTo(hw, hl * 0.55)
      ..cubicTo(hw, hl, -hw, hl, -hw, hl * 0.55)         // tail
      ..lineTo(-hw, -hl * 0.25)
      ..cubicTo(-hw, -hl * 0.45, -hw, -hl, 0, -hl)
      ..close();
    c.drawPath(body, Paint()
      ..color = Colors.black.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    c.drawPath(body, Paint()..color = light ? const Color(0xFFFFFFFF) : const Color(0xFF2A2C31));
    c.drawPath(body, Paint()
      ..color = accent ..style = PaintingStyle.stroke ..strokeWidth = 2.2);
    // windshield hint + heading nub
    if (L > 34) {
      final glass = Path()
        ..moveTo(-hw * 0.62, -hl * 0.12)..lineTo(hw * 0.62, -hl * 0.12)
        ..lineTo(hw * 0.42, -hl * 0.4)..lineTo(-hw * 0.42, -hl * 0.4)..close();
      c.drawPath(glass, Paint()..color = accent.withValues(alpha: 0.35));
    }
    c.restore();
  }

  @override
  bool shouldRepaint(covariant _MapPainter o) =>
      o.s != s || o.scale != scale || o.dest != dest || o.lanes != lanes || o.polys != polys || o.rot != rot || o.light != light;  // s carries routePath
}
