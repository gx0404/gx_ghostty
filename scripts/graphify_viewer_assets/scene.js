/* Offline renderer. Layout and picking are shared by WebGL and Canvas 2D. */
(function (global) {
  'use strict';
  const T = global.AtlasVendor;
  const CYAN = '#73c8d5', AMBER = '#e6b06b';
  function hash(s) { let h = 2166136261; for (const c of String(s)) h = Math.imul(h ^ c.charCodeAt(0), 16777619); return h >>> 0; }
  function random(seed) { let x = seed || 1; return function () { x ^= x << 13; x ^= x >>> 17; x ^= x << 5; return (x >>> 0) / 4294967296; }; }
  function create(options) {
    const host = options.host, labels = options.labels, tooltip = options.tooltip;
    let canvas, gl, world, camera, group, flat, mode = '2d', reason = '', width = 1, height = 1;
    let data = {items: [], edges: []}, projected = [], labelElements = [], raf = 0;
    let yaw = 0, pitch = .18, zoom = 1, panX = 0, panY = 0, pointer = null, hover = -1;
    let reduced = options.reducedMotion, disposed = false, animatedUntil = 0, lastTime = 0;
    const metrics = {frames: 0, firstFrameMs: null, renderer: '', mode: '', reason: '', draws: []};
    const stars = []; const rand = random(172923);
    for (let i = 0; i < 180; i++) stars.push([rand(), rand(), rand()]);
    function makeCanvas() { const c = document.createElement('canvas'); c.setAttribute('aria-hidden', 'true'); host.prepend(c); return c; }
    function announce() { metrics.mode = mode; metrics.reason = reason; options.onModeChange({mode: mode, reason: reason, renderer: metrics.renderer}); }
    function clearGroup() {
      if (!group) return;
      while (group.children.length) {
        const child = group.children[0]; group.remove(child);
        if (child.geometry) child.geometry.dispose();
        if (child.material) { const ms = Array.isArray(child.material) ? child.material : [child.material]; ms.forEach(m => m.dispose()); }
      }
    }
    function disposeGL() { clearGroup(); if (gl) { gl.dispose(); gl = null; } if (canvas) canvas.remove(); }
    function startFlat(why) {
      disposeGL(); mode = '2d'; reason = why || 'manual'; canvas = makeCanvas(); flat = canvas.getContext('2d');
      metrics.renderer = 'Canvas 2D'; resize(); announce(); invalidate();
    }
    function startGL() {
      if (!T || !T.WebGLRenderer) { startFlat('vendor-missing'); return; }
      if (canvas) canvas.remove(); canvas = makeCanvas();
      let context;
      try { context = canvas.getContext('webgl2', {alpha: false, antialias: true}); } catch (_) { context = null; }
      if (!context) { startFlat('webgl-unavailable'); return; }
      try {
        gl = new T.WebGLRenderer({canvas: canvas, context: context, antialias: true, alpha: false});
        gl.setClearColor('#101b27'); gl.setPixelRatio(Math.min(global.devicePixelRatio || 1, 2));
        world = new T.Scene(); camera = new T.PerspectiveCamera(45, 1, 1, 3000); group = new T.Group(); world.add(group);
        const dbg = context.getExtension('WEBGL_debug_renderer_info');
        metrics.renderer = dbg ? context.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : context.getParameter(context.RENDERER);
        canvas.addEventListener('webglcontextlost', function (event) { event.preventDefault(); startFlat('context-lost'); });
        mode = '3d'; reason = ''; flat = null; rebuild(); resize(); announce();
      } catch (_) { startFlat('webgl-unavailable'); }
    }
    function points(items, decorative) {
      const positions = [], colors = [], sizes = [];
      items.forEach(item => {
        positions.push(item.x || 0, item.y || 0, item.z || 0);
        const color = new T.Color(item.color || CYAN); colors.push(color.r, color.g, color.b);
        sizes.push(item.size || 5);
      });
      const geometry = new T.BufferGeometry();
      geometry.setAttribute('position', new T.Float32BufferAttribute(positions, 3));
      geometry.setAttribute('color', new T.Float32BufferAttribute(colors, 3));
      geometry.setAttribute('pointSize', new T.Float32BufferAttribute(sizes, 1));
      const material = new T.ShaderMaterial({
        transparent: true, depthWrite: false, blending: T.AdditiveBlending, vertexColors: true,
        uniforms: {pixelRatio: {value: Math.min(global.devicePixelRatio || 1, 2)}, opacity: {value: decorative ? .38 : 1}},
        vertexShader: 'attribute float pointSize; varying vec3 vColor; uniform float pixelRatio; void main(){vColor=color; vec4 mv=modelViewMatrix*vec4(position,1.0); gl_PointSize=clamp(pointSize*pixelRatio*1300.0/-mv.z,2.0,110.0); gl_Position=projectionMatrix*mv;}',
        fragmentShader: 'varying vec3 vColor; uniform float opacity; void main(){float d=length(gl_PointCoord-vec2(.5))*2.0; if(d>1.0)discard; float a=pow(1.0-d,1.8); float core=1.0-smoothstep(.0,.2,d); gl_FragColor=vec4(vColor+vec3(core*.35),max(a,core*.72)*opacity);}'
      });
      group.add(new T.Points(geometry, material));
    }
    function rebuild() {
      if (!gl) return; clearGroup();
      const byKey = new Map(data.items.map(item => [item.key, item]));
      const decorations = [];
      data.items.forEach(item => {
        if (!item.cluster) return;
        const r = random(hash(item.key)), count = Math.min(80, Math.max(5, Math.floor(Math.sqrt(item.count || 1) * 2)));
        for (let j = 0; j < count; j++) {
          const a = r() * Math.PI * 2, radius = 3 + Math.sqrt(r()) * (9 + Math.log2((item.count || 1) + 1) * 1.3);
          decorations.push({x: item.x + Math.cos(a) * radius, y: item.y + Math.sin(a) * radius * .66, z: item.z + (r() - .5) * 20, size: 2 + r() * 3, color: item.color});
        }
      });
      if (decorations.length) points(decorations, true);
      data.edges.forEach(edge => {
        const a = byKey.get(edge.source), b = byKey.get(edge.target); if (!a || !b || a === b) return;
        const middle = new T.Vector3((a.x + b.x) / 2, (a.y + b.y) / 2 + 8, ((a.z || 0) + (b.z || 0)) / 2 - 10);
        const curve = new T.QuadraticBezierCurve3(new T.Vector3(a.x, a.y, a.z || 0), middle, new T.Vector3(b.x, b.y, b.z || 0));
        const geometry = new T.BufferGeometry().setFromPoints(curve.getPoints(20));
        const material = edge.inferred ? new T.LineDashedMaterial({color: AMBER, transparent: true, opacity: .6, dashSize: 3, gapSize: 2}) : new T.LineBasicMaterial({color: '#6098ad', transparent: true, opacity: .3});
        const line = new T.Line(geometry, material); line.computeLineDistances(); group.add(line);
      });
      points(data.items, false);
    }
    function project() {
      if (gl) {
        const distance = Math.max(470, 470 / Math.max(width / height, .6)) / zoom;
        camera.aspect = width / height; camera.updateProjectionMatrix();
        camera.position.set(Math.sin(yaw) * Math.cos(pitch) * distance, Math.sin(pitch) * distance, Math.cos(yaw) * Math.cos(pitch) * distance);
        camera.lookAt(panX, panY, 0); camera.updateMatrixWorld();
        projected = data.items.map(item => {
          const v = new T.Vector3(item.x, item.y, item.z || 0).project(camera);
          return {x: (v.x + 1) * width / 2, y: (1 - v.y) * height / 2, visible: v.z > -1 && v.z < 1};
        });
      } else {
        const scale = Math.min(width / 510, height / 440) * zoom;
        projected = data.items.map(item => ({x: width / 2 + (item.x - panX) * scale, y: height / 2 - (item.y - panY) * scale, visible: true}));
      }
    }
    function placeLabels() {
      const occupied = [];
      for (const entry of labelElements) {
        const p = projected[entry.index], item = data.items[entry.index];
        let visible = p && p.visible && p.x > 15 && p.x < width - 75 && p.y > 80 && p.y < height - 95;
        const remainingWidth = p ? Math.max(20, width - p.x - 18) : 20;
        const box = visible ? {x: p.x + 10, y: p.y - 12, w: Math.min(180, remainingWidth, item.label.length * 6 + 15), h: item.cluster ? 34 : 22} : null;
        if (visible && occupied.some(r => box.x < r.x + r.w && box.x + box.w > r.x && box.y < r.y + r.h && box.y + box.h > r.y)) visible = false;
        entry.el.hidden = !visible;
        if (visible) { occupied.push(box); entry.el.style.left = p.x + 'px'; entry.el.style.top = p.y + 'px'; entry.el.style.maxWidth = Math.min(180, remainingWidth) + 'px'; }
      }
    }
    function renderFlat() {
      if (!flat) return;
      const dpr = Math.min(global.devicePixelRatio || 1, 2); flat.setTransform(dpr, 0, 0, dpr, 0, 0);
      flat.fillStyle = '#101b27'; flat.fillRect(0, 0, width, height);
      const background = flat.createRadialGradient(width * .52, height * .43, 10, width * .52, height * .43, width * .6);
      background.addColorStop(0, '#1a3245'); background.addColorStop(1, '#101b27'); flat.fillStyle = background; flat.fillRect(0, 0, width, height);
      stars.forEach(s => { flat.fillStyle = 'rgba(160,196,216,' + (.1 + s[2] * .25) + ')'; flat.fillRect(s[0] * width, s[1] * height, 1, 1); });
      const lookup = new Map(data.items.map((it, i) => [it.key, projected[i]]));
      data.edges.forEach(edge => {
        const a = lookup.get(edge.source), b = lookup.get(edge.target); if (!a || !b) return;
        flat.strokeStyle = edge.inferred ? 'rgba(230,176,107,.6)' : 'rgba(100,162,187,.32)'; flat.setLineDash(edge.inferred ? [4, 4] : []);
        flat.beginPath(); flat.moveTo(a.x, a.y); flat.quadraticCurveTo((a.x + b.x) / 2, (a.y + b.y) / 2 - 12, b.x, b.y); flat.stroke();
      }); flat.setLineDash([]);
      data.items.forEach((item, i) => {
        const p = projected[i], radius = Math.max(3, (item.size || 6) * .55);
        const glow = flat.createRadialGradient(p.x, p.y, 0, p.x, p.y, radius * 4);
        glow.addColorStop(0, item.color || CYAN); glow.addColorStop(.16, (item.color || CYAN) + 'b0'); glow.addColorStop(1, (item.color || CYAN) + '00');
        flat.fillStyle = glow; flat.beginPath(); flat.arc(p.x, p.y, radius * 4, 0, Math.PI * 2); flat.fill();
        flat.fillStyle = '#e6f7fc'; flat.beginPath(); flat.arc(p.x, p.y, Math.max(1, radius * .34), 0, Math.PI * 2); flat.fill();
      });
    }
    function frame(now) {
      raf = 0; if (disposed || document.hidden) return;
      if (animatedUntil > now && !reduced) yaw += Math.min(30, now - (lastTime || now)) * .00012;
      lastTime = now; project(); if (gl) gl.render(world, camera); else renderFlat(); placeLabels();
      metrics.frames++; if (metrics.firstFrameMs === null) metrics.firstFrameMs = performance.now();
      metrics.draws.push(performance.now()); if (metrics.draws.length > 600) metrics.draws.shift();
      if (animatedUntil > now && !reduced) invalidate();
    }
    function invalidate() { if (!raf && !disposed && !document.hidden) raf = requestAnimationFrame(frame); }
    function resize() {
      width = Math.max(1, host.clientWidth); height = Math.max(1, host.clientHeight);
      if (gl) gl.setSize(width, height, false);
      else if (canvas) { const dpr = Math.min(global.devicePixelRatio || 1, 2); canvas.width = Math.round(width * dpr); canvas.height = Math.round(height * dpr); }
      invalidate();
    }
    function setData(next) {
      data = next; hover = -1; tooltip.hidden = true; labels.replaceChildren();
      labelElements = data.items.map((item, index) => ({item: item, index: index})).sort((a, b) => (b.item.priority || b.item.count || 0) - (a.item.priority || a.item.count || 0)).slice(0, 30).map(entry => {
        const el = document.createElement('div'); el.className = 'map-label' + (entry.item.priority || entry.item.cluster ? ' important' : '');
        el.append(document.createTextNode(entry.item.label));
        if (entry.item.cluster) { const small = document.createElement('small'); small.textContent = (entry.item.count || 0).toLocaleString() + ' 个节点'; el.append(small); }
        labels.append(el); return {index: entry.index, el: el};
      });
      yaw = 0; pitch = .18; zoom = 1; panX = panY = 0; rebuild(); invalidate();
    }
    function nearest(x, y) {
      let best = -1, d = 19 * 19;
      projected.forEach((p, i) => { if (!p.visible) return; const dd = (x - p.x) ** 2 + (y - p.y) ** 2; if (dd < d) { d = dd; best = i; } }); return best;
    }
    function local(event) { const r = host.getBoundingClientRect(); return {x: event.clientX - r.left, y: event.clientY - r.top}; }
    host.addEventListener('pointerdown', event => { if (event.button !== 0) return; const p = local(event); pointer = {x: p.x, y: p.y, startX: p.x, startY: p.y, id: event.pointerId}; host.setPointerCapture(event.pointerId); host.focus({preventScroll: true}); });
    host.addEventListener('pointermove', event => {
      const p = local(event);
      if (pointer) {
        const dx = p.x - pointer.x, dy = p.y - pointer.y;
        if (gl) { yaw -= dx * .006; pitch = Math.max(-1.1, Math.min(1.1, pitch + dy * .005)); }
        else { panX -= dx / zoom; panY += dy / zoom; }
        pointer.x = p.x; pointer.y = p.y; tooltip.hidden = true; invalidate(); return;
      }
      hover = nearest(p.x, p.y); host.style.cursor = hover >= 0 ? 'pointer' : 'grab';
      tooltip.hidden = hover < 0;
      if (hover >= 0) { tooltip.textContent = data.items[hover].label; tooltip.style.left = Math.max(8, Math.min(width - 235, p.x + 15)) + 'px'; tooltip.style.top = Math.max(10, p.y - 37) + 'px'; }
    });
    host.addEventListener('pointerup', event => {
      if (!pointer) return; const p = local(event), clicked = Math.hypot(p.x - pointer.startX, p.y - pointer.startY) < 5; pointer = null;
      if (host.hasPointerCapture(event.pointerId)) host.releasePointerCapture(event.pointerId);
      if (clicked) { const index = nearest(p.x, p.y); if (index >= 0) options.onSelect(data.items[index]); }
    });
    host.addEventListener('pointercancel', () => { pointer = null; });
    host.addEventListener('pointerleave', () => { tooltip.hidden = true; });
    host.addEventListener('wheel', event => { event.preventDefault(); zoom = Math.max(.45, Math.min(5, zoom * Math.exp(-event.deltaY * .001))); invalidate(); }, {passive: false});
    host.addEventListener('keydown', event => {
      let handled = true;
      if (event.key === '+' || event.key === '=') zoom = Math.min(5, zoom * 1.15);
      else if (event.key === '-') zoom = Math.max(.45, zoom / 1.15);
      else if (event.key === '0') { yaw = 0; pitch = .18; zoom = 1; panX = panY = 0; }
      else if (event.key === 'ArrowLeft') { if (gl) yaw -= .1; else panX -= 15; }
      else if (event.key === 'ArrowRight') { if (gl) yaw += .1; else panX += 15; }
      else if (event.key === 'ArrowUp') { if (gl) pitch = Math.min(1.1, pitch + .1); else panY += 15; }
      else if (event.key === 'ArrowDown') { if (gl) pitch = Math.max(-1.1, pitch - .1); else panY -= 15; }
      else handled = false;
      if (handled) { event.preventDefault(); invalidate(); }
    });
    const observer = new ResizeObserver(resize); observer.observe(host);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) { lastTime = 0; invalidate(); } });
    startGL();
    return {
      setData: setData,
      setMode: function (newMode) { if (newMode === '2d') startFlat('manual'); else startGL(); },
      reset: function () { yaw = 0; pitch = .18; zoom = 1; panX = panY = 0; invalidate(); },
      zoom: function (amount) { zoom = Math.max(.45, Math.min(5, zoom * amount)); invalidate(); },
      setReducedMotion: function (value) { reduced = value; if (value) animatedUntil = 0; invalidate(); },
      animateFor: function (duration) { animatedUntil = performance.now() + Math.min(5000, Math.max(0, duration)); lastTime = 0; invalidate(); },
      metrics: function () { return {mode: mode, reason: reason, renderer: metrics.renderer, frames: metrics.frames, firstFrameMs: metrics.firstFrameMs, draws: metrics.draws.slice(), visibleNodes: data.items.length, visibleEdges: data.edges.length, reducedMotion: reduced}; },
      loseContext: function () { if (gl) { const extension = gl.getContext().getExtension('WEBGL_lose_context'); if (extension) extension.loseContext(); } },
      dispose: function () { disposed = true; if (raf) cancelAnimationFrame(raf); observer.disconnect(); disposeGL(); }
    };
  }
  global.GXAtlasScene = {create: create, hash: hash, random: random};
})(window);
