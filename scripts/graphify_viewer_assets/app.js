/* Catalog UI and lazy classic-script relations. No network service is required. */
(function (global) {
  'use strict';
  const started = performance.now(), $ = id => document.getElementById(id);
  const metrics = {readyMs: null, filterMs: [], filterVersion: 0, loadedShards: 0};
  function element(tag, text, className) { const el = document.createElement(tag); if (text !== undefined) el.textContent = text; if (className) el.className = className; return el; }
  function fatal(message) { $('fatalError').textContent = message; $('fatalError').hidden = false; }
  let catalog;
  try { catalog = JSON.parse($('graph-data').textContent); } catch (_) { fatal('目录数据无法读取。请重新生成离线星图。'); return; }
  if (catalog.schema !== 1 || !Array.isArray(catalog.nodes) || !Array.isArray(catalog.files) || !Array.isArray(catalog.modules)) { fatal('目录版本不受支持。请重新生成离线星图。'); return; }
  const nodes = catalog.nodes, files = catalog.files, modules = catalog.modules, stats = catalog.stats || {};
  const N = {id: 0, label: 1, file: 2, start: 3, end: 4, module: 5, kind: 6, community: 7, external: 8, locators: 9, degree: 10};
  const E = {id: 0, other: 1, source: 2, target: 3, relation: 4, evidence: 5, score: 6, file: 7, start: 8, end: 9, context: 10};
  const kindNames = {file: '文件', class: '类型', function: '函数', symbol: '符号'};
  const kindMarks = {file: 'F', class: 'T', function: 'ƒ', symbol: '·'};
  const byId = new Map(), moduleNodes = modules.map(() => []), fileNodes = files.map(() => []), searchText = [];
  nodes.forEach((n, i) => {
    byId.set(n[N.id], i);
    if (moduleNodes[n[N.module]]) moduleNodes[n[N.module]].push(i);
    if (fileNodes[n[N.file]]) fileNodes[n[N.file]].push(i);
    searchText.push([n[N.label], n[N.id], files[n[N.file]] ? files[n[N.file]][0] : '', modules[n[N.module]] || ''].join(' ').toLocaleLowerCase());
  });
  const ranked = nodes.map((_, i) => i).sort((a, b) => (nodes[b][N.degree] || 0) - (nodes[a][N.degree] || 0) || a - b);
  const mediaMotion = matchMedia('(prefers-reduced-motion: reduce)'), mediaNarrow = matchMedia('(max-width: 700px)'), mediaMedium = matchMedia('(max-width: 1100px)');
  const state = {selected: -1, matched: ranked.slice(), resultLimit: 200, level: 'overview', module: -1, file: -1, relationRows: [], nextPage: 0, request: 0, loading: false, reduced: mediaMotion.matches, immersive: false, moduleExpanded: false};
  const shardCache = new Map(), records = new Map();
  let scene, filterTimer = null, filterStarted = 0, helpReturn = null;
  function number(value) { return Number(value || 0).toLocaleString(); }
  function filePath(n) { return files[n[N.file]] ? files[n[N.file]][0] : '暂无可验证来源'; }
  function pathLine(n) { return filePath(n) + (n[N.start] > 0 ? ':' + n[N.start] : ''); }
  function filename(path) { return path.split('/').pop() || path; }
  function sourceHref(file, line) { return files[file] && files[file][2] ? files[file][2] + (line > 0 ? '#L' + line : '') : null; }
  function note(text, warn) { $('mapNotice').textContent = text; $('mapNotice').hidden = !text; $('mapNotice').classList.toggle('warn', !!warn); }
  function setPanel(which, open, focus) {
    const panel = $(which === 'list' ? 'listPanel' : 'detailPanel'), button = $(which === 'list' ? 'showList' : 'showDetail');
    const wasOpen = panel.classList.contains('open'), hadFocus = panel.contains(document.activeElement);
    if (open && mediaNarrow.matches) {
      const other = which === 'list' ? 'detail' : 'list';
      $(other === 'list' ? 'listPanel' : 'detailPanel').classList.remove('open');
      $(other === 'list' ? 'showList' : 'showDetail').setAttribute('aria-expanded', 'false');
    }
    panel.classList.toggle('open', open); button.setAttribute('aria-expanded', String(open));
    if (!open && (hadFocus || wasOpen) && button.offsetParent) button.focus({preventScroll: true});
    if (open && focus) { const target = panel.querySelector('button,select,a,input'); if (target) target.focus({preventScroll: true}); }
  }
  function setImmersive(value) {
    state.immersive = value; document.body.classList.toggle('immersive', value);
    $('toggleExplore').setAttribute('aria-pressed', String(value)); $('toggleExplore').textContent = value ? '返回分析' : '沉浸探索';
    if (value && ($('listPanel').contains(document.activeElement) || $('detailPanel').contains(document.activeElement))) $('toggleExplore').focus();
  }
  modules.forEach((m, i) => $('module').append(new Option(m + ' (' + number(moduleNodes[i].length) + ')', String(i))));
  Array.from(new Set(nodes.map(n => n[N.kind]))).sort().forEach(kind => $('kind').append(new Option(kindNames[kind] || kind, kind)));
  $('catalogCount').textContent = number(nodes.length) + ' 节点';
  const statRows = [[stats.nodes || nodes.length, '节点'], [stats.edges, '关系'], [modules.length, '模块'], [(stats.evidence || {}).INFERRED || 0, '推断关系']];
  statRows.forEach(row => { const d = element('div'); d.append(element('dt', row[1]), element('dd', number(row[0]))); $('stats').append(d); });
  const limitationList = (catalog.limitations || []).slice();
  limitationList.push('无可验证来源的节点：' + number(stats.unknownSources) + '；自环关系：' + number(stats.selfLoops) + '。');
  limitationList.forEach(text => $('limitations').append(element('li', text)));
  $('fingerprint').textContent = '构建指纹 ' + (catalog.fingerprint || '未知');
  $('reduceMotion').checked = state.reduced;
  function moduleDistribution() {
    const sorted = modules.map((name, i) => ({name: name, i: i, count: moduleNodes[i].length})).sort((a, b) => b.count - a.count || a.i - b.i);
    $('moduleList').replaceChildren();
    const visible = state.moduleExpanded ? sorted : sorted.slice(0, 7), largest = sorted[0] ? sorted[0].count : 1;
    visible.forEach(m => {
      const li = element('li'), button = element('button'); button.type = 'button'; button.dataset.module = String(m.i);
      const row = element('span', undefined, 'module-row'); row.append(element('span', m.name), element('span', number(m.count)));
      const bar = element('span', undefined, 'module-bar'), fill = element('i'); fill.style.width = Math.max(1, m.count / largest * 100) + '%'; bar.append(fill); button.append(row, bar);
      button.addEventListener('click', () => focusModule(m.i)); li.append(button); $('moduleList').append(li);
    });
    $('moreModules').hidden = sorted.length <= 7; $('moreModules').textContent = state.moduleExpanded ? '收起模块列表' : '查看全部 ' + sorted.length + ' 个模块';
  }
  function renderResults() {
    const fragment = document.createDocumentFragment();
    state.matched.slice(0, state.resultLimit).forEach(i => {
      const n = nodes[i], li = element('li'), button = element('button', undefined, 'result-button' + (state.selected === i ? ' selected' : ''));
      button.type = 'button'; button.dataset.node = String(i); button.setAttribute('aria-pressed', String(state.selected === i));
      const row = element('span', undefined, 'result-title'); row.append(element('span', kindMarks[n[N.kind]] || '·', 'kind-mark'), element('strong', n[N.label]));
      button.append(row, element('span', pathLine(n), 'result-path')); button.title = n[N.label] + '\n' + pathLine(n);
      button.addEventListener('click', () => selectNode(i, true)); li.append(button); fragment.append(li);
    });
    $('results').replaceChildren(fragment); $('resultCount').textContent = number(state.matched.length) + ' 个节点';
    $('emptyResults').hidden = state.matched.length > 0; $('moreResults').hidden = state.resultLimit >= state.matched.length;
    $('moreResults').textContent = '再显示 ' + Math.min(200, state.matched.length - state.resultLimit) + ' 个结果';
  }
  function applyFilter() {
    filterTimer = null; const q = $('search').value.trim().toLocaleLowerCase(), tokens = q.split(/\s+/).filter(Boolean), mod = $('module').value, kind = $('kind').value;
    state.matched = ranked.filter(i => (!mod || nodes[i][N.module] === Number(mod)) && (!kind || nodes[i][N.kind] === kind) && tokens.every(token => searchText[i].includes(token)));
    if (q) state.matched.sort((a, b) => Number(nodes[b][N.label].toLocaleLowerCase() === q) - Number(nodes[a][N.label].toLocaleLowerCase() === q) || (nodes[b][N.degree] || 0) - (nodes[a][N.degree] || 0) || a - b);
    state.resultLimit = 200; renderResults();
    if (q || kind) drawSearch(); else if (mod) drawModule(Number(mod)); else if (state.selected < 0) drawOverview();
    metrics.filterVersion++; metrics.filterMs.push(performance.now() - (filterStarted || performance.now()));
    if (mediaNarrow.matches && q) setPanel('list', true, false);
  }
  function scheduleFilter(immediate) { if (filterTimer) clearTimeout(filterTimer); filterStarted = performance.now(); if (immediate) applyFilter(); else filterTimer = setTimeout(applyFilter, 65); }
  function breadcrumb(entries) {
    $('fileJumpWrap').hidden = true;
    $('breadcrumbs').replaceChildren();
    const home = element('button', '源码全景'); home.type = 'button'; home.addEventListener('click', resetAll); $('breadcrumbs').append(home);
    entries.forEach(entry => { $('breadcrumbs').append(element('span', '/')); const b = element('button', entry.label); b.type = 'button'; b.addEventListener('click', entry.action); $('breadcrumbs').append(b); });
  }
  const palette = ['#73c8d5', '#8eafd6', '#b1bfdc', '#82b7ca', '#a9cbd5', '#8c9fc6'];
  function spiral(items, spread) {
    if (items.length === 1) return [Object.assign({}, items[0], {x: 0, y: 0, z: 0})];
    return items.map((item, i) => { const a = i * 2.399963229728653, r = 15 + Math.sqrt((i + .6) / Math.max(items.length, 1)) * spread; const rnd = global.GXAtlasScene.random(global.GXAtlasScene.hash(item.key));
      return Object.assign({}, item, {x: Math.cos(a) * r, y: Math.sin(a) * r * .78, z: (rnd() - .5) * 48}); });
  }
  function setMap(items, edges, total, description) {
    scene.setData({items: items, edges: edges});
    $('sceneCount').textContent = (items.length < total ? number(items.length) + ' / ' + number(total) : number(total)) + ' ' + description;
    if (items.length < total) note('画面显示 ' + items.length + ' / ' + total + ' 个' + description + '。完整结果仍可在左侧搜索与分页。', false); else note('', false);
  }
  function drawOverview() {
    state.level = 'overview'; state.module = state.file = -1; $('mapIntro').hidden = false; breadcrumb([]);
    const items = spiral(modules.map((m, i) => ({key: 'm' + i, type: 'module', index: i, label: m, count: moduleNodes[i].length, cluster: true, size: 10 + Math.log2(moduleNodes[i].length + 1) * 1.5, color: palette[i % palette.length]})), 192);
    const edges = (catalog.moduleRelations || []).slice().sort((a, b) => b[2] - a[2] || a[0] - b[0] || a[1] - b[1]).slice(0, 36).map(row => ({source: 'm' + row[0], target: 'm' + row[1], inferred: row[3] === row[2]}));
    setMap(items, edges, items.length, '个模块');
    const totalEdges = (catalog.moduleRelations || []).length;
    $('sceneCount').textContent += ' · ' + edges.length + ' / ' + totalEdges + ' 条聚合关系';
  }
  function drawModule(index) {
    state.level = 'module'; state.module = index; state.file = -1; $('mapIntro').hidden = true;
    breadcrumb([{label: modules[index], action: () => focusModule(index)}]);
    const counts = new Map(); (moduleNodes[index] || []).forEach(i => { const f = nodes[i][N.file]; if (f >= 0) counts.set(f, (counts.get(f) || 0) + 1); });
    if (!counts.size) { drawSymbols(moduleNodes[index] || [], '个符号'); return; }
    $('fileJump').replaceChildren(new Option('选择文件继续展开', ''));
    Array.from(counts.keys()).sort((a, b) => files[a][0] < files[b][0] ? -1 : files[a][0] > files[b][0] ? 1 : 0).forEach(f => $('fileJump').append(new Option(files[f][0], String(f))));
    $('fileJumpWrap').hidden = false;
    const items = spiral(Array.from(counts.entries()).sort((a, b) => b[1] - a[1] || a[0] - b[0]).map(([f, count]) => ({key: 'f' + f, type: 'file', index: f, label: filename(files[f][0]), count: count, cluster: true, size: 8 + Math.log2(count + 1), color: palette[index % palette.length]})).slice(0, 2000), 180);
    setMap(items, [], counts.size, '个文件');
  }
  function drawSymbols(indices, label) {
    const ordered = indices.slice().sort((a, b) => (nodes[b][N.degree] || 0) - (nodes[a][N.degree] || 0) || a - b);
    const items = spiral(ordered.slice(0, 2000).map(i => ({key: 'n' + i, type: 'node', index: i, label: nodes[i][N.label], size: 7 + Math.min(9, Math.log2((nodes[i][N.degree] || 0) + 1)), color: palette[nodes[i][N.module] % palette.length], priority: nodes[i][N.degree] || 0})), 182);
    setMap(items, [], indices.length, label);
  }
  function drawFile(file) {
    state.level = 'file'; state.file = file; $('mapIntro').hidden = true;
    const indices = fileNodes[file] || [], mod = indices.length ? nodes[indices[0]][N.module] : state.module; state.module = mod;
    breadcrumb([{label: modules[mod] || '来源文件', action: () => focusModule(mod)}, {label: filename(files[file][0]), action: () => focusFile(file)}]);
    drawSymbols(indices, '个符号');
  }
  function drawSearch() { state.level = 'search'; $('mapIntro').hidden = true; breadcrumb([{label: '筛选结果', action: () => scheduleFilter(true)}]); drawSymbols(state.matched, '个匹配节点'); }
  function focusModule(index) {
    clearSelection(); $('search').value = ''; $('kind').value = ''; $('module').value = String(index); scheduleFilter(true); drawModule(index);
    setPanel('detail', false, false); if (mediaNarrow.matches) setPanel('list', false, false);
  }
  function focusFile(index) {
    clearSelection(); const indices = fileNodes[index] || []; state.matched = indices.slice(); state.resultLimit = 200; renderResults(); drawFile(index);
    if (mediaNarrow.matches) setPanel('list', true, false);
  }
  function clearSelection() {
    state.selected = -1; state.request++; state.relationRows = []; state.nextPage = 0;
    $('nodeInfo').hidden = true; $('overviewInfo').hidden = false; $('detailHeading').textContent = '图谱分析';
    if (location.hash) history.replaceState(null, '', location.pathname + location.search);
  }
  function resetAll() { clearSelection(); $('search').value = ''; $('module').value = ''; $('kind').value = ''; scheduleFilter(true); drawOverview(); }
  function setSelection(index) {
    const n = nodes[index], s = $('selection'); s.replaceChildren();
    s.append(element('h2', n[N.label], 'node-title'));
    const meta = element('div', undefined, 'node-meta'); meta.append(element('span', kindNames[n[N.kind]] || n[N.kind], 'pill'), element('span', modules[n[N.module]] || '外部节点', 'pill'));
    if (catalog.communities && catalog.communities[n[N.community]]) meta.append(element('span', catalog.communities[n[N.community]], 'pill'));
    s.append(meta, element('p', pathLine(n), 'node-path'));
    const links = element('div', undefined, 'source-actions'), href = sourceHref(n[N.file], n[N.start]);
    if (href) { const a = element('a', '查看来源快照' + (n[N.start] ? ' · 第 ' + n[N.start] + ' 行' : '')); a.href = href; a.id = 'sourceLink'; links.append(a); }
    else s.append(element('p', '暂无可验证来源。此节点可能是外部引用或占位信息。', 'selection-note'));
    const cross = element('a', document.body.dataset.view === 'detail' ? '返回全景并定位' : '打开独立一跳关系视图');
    cross.href = (document.body.dataset.view === 'detail' ? 'overview.html' : 'detail.html') + '#' + encodeURIComponent(n[N.id]); cross.id = 'nodeViewLink'; links.append(cross); s.append(links);
    if (files[n[N.file]]) s.append(element('p', '文件 SHA-256 ' + files[n[N.file]][1], 'hash'));
    s.append(element('p', '关系表示提取器记录的连接；证据等级与方向不等于已核实的完整调用链。', 'selection-note'));
    $('nodeInfo').hidden = false; $('overviewInfo').hidden = true; $('detailHeading').textContent = '节点详情';
  }
  function selectNode(index, push) {
    if (!nodes[index]) return;
    state.selected = index; state.request++; state.relationRows = []; state.nextPage = 0; state.loading = false;
    $('evidence').value = ''; $('relationError').hidden = true; setSelection(index); renderResults();
    if (push) history.pushState({node: index}, '', '#' + encodeURIComponent(nodes[index][N.id]));
    $('alternateView').href = (document.body.dataset.view === 'detail' ? 'overview.html' : 'detail.html') + '#' + encodeURIComponent(nodes[index][N.id]);
    if (state.immersive) setImmersive(false); if (mediaMedium.matches) setPanel('detail', true, false);
    $('detailPanel').scrollTop = 0; drawNeighbors(); loadNextRelations();
  }
  function loadShard(id) {
    if (shardCache.has(id)) return shardCache.get(id).promise;
    const path = (catalog.shards || [])[id];
    if (typeof path !== 'string' || !/^data\/relations-\d+\.js$/.test(path)) return Promise.reject(new Error('关系分片路径无效'));
    const entry = {registered: false}, script = document.createElement('script'); script.src = path; script.async = true;
    entry.promise = new Promise((resolve, reject) => {
      entry.resolve = resolve; entry.reject = reject;
      const timer = setTimeout(() => fail('读取关系超时'), 10000);
      function fail(message) { clearTimeout(timer); script.remove(); shardCache.delete(id); reject(new Error(message)); }
      entry.fail = fail;
      script.onload = function () { clearTimeout(timer); if (!entry.registered) { fail('关系分片没有返回有效数据'); return; } resolve(); };
      script.onerror = function () { fail('无法读取本地关系分片。请确认 data 文件夹完整。'); };
    });
    shardCache.set(id, entry); document.head.append(script); return entry.promise;
  }
  global.GXAtlas = {
    register: function (fingerprint, shardId, rows) {
      const entry = shardCache.get(shardId); if (!entry) return;
      if (fingerprint !== catalog.fingerprint || !Array.isArray(rows)) { entry.fail('关系分片与当前目录不匹配，请重新生成星图。'); return; }
      for (const row of rows) {
        if (!Array.isArray(row) || !nodes[row[0]] || !Number.isInteger(row[1]) || !Array.isArray(row[2])) { entry.fail('关系分片结构不正确'); return; }
      }
      rows.forEach(row => records.set(row[0] + ':' + row[1], row[2])); entry.registered = true; metrics.loadedShards++;
    }
  };
  async function loadNextRelations() {
    const index = state.selected, request = state.request;
    if (index < 0 || state.loading) return;
    const locators = nodes[index][N.locators] || [];
    if (state.nextPage >= locators.length) { renderRelations(); drawNeighbors(); return; }
    const locator = locators[state.nextPage]; state.loading = true; $('relationError').hidden = true; $('relationStatus').textContent = '正在读取本地关系…'; $('moreRelations').disabled = true;
    try {
      await loadShard(locator[0]); if (request !== state.request) return;
      const rows = records.get(index + ':' + locator[1]); if (!rows) throw new Error('关系分片缺少指定节点页');
      state.relationRows.push(...rows); state.nextPage++; state.loading = false; renderRelations(); drawNeighbors();
    } catch (error) {
      if (request !== state.request) return; state.loading = false;
      $('relationErrorText').textContent = error.message; $('relationError').hidden = false; $('relationStatus').textContent = '关系读取失败；全局搜索和来源快照仍可使用。'; $('moreRelations').disabled = false;
    }
  }
  function visibleRelations() { const ev = $('evidence').value; return state.relationRows.filter(row => !ev || row[E.evidence] === ev); }
  function renderRelations() {
    if (state.selected < 0) return;
    const n = nodes[state.selected], rows = visibleRelations(), fragment = document.createDocumentFragment();
    rows.forEach(row => {
      const other = nodes[row[E.other]]; if (!other) return;
      const li = element('li', undefined, 'relation' + (row[E.evidence] === 'INFERRED' ? ' inferred' : ''));
      const evidence = row[E.evidence] === 'EXTRACTED' ? '直接提取' : row[E.evidence] === 'INFERRED' ? '推断 · 待核实' : row[E.evidence];
      const direction = row[E.source] === row[E.target] ? '自环' : row[E.source] === state.selected ? '此节点 → 邻居' : '邻居 → 此节点';
      li.append(element('div', direction + ' / ' + row[E.relation] + ' / ' + evidence, 'relation-top'));
      const button = element('button', other[N.label]); button.type = 'button'; button.dataset.neighbor = String(row[E.other]); button.addEventListener('click', () => selectNode(row[E.other], true)); li.append(button);
      const href = sourceHref(row[E.file], row[E.start]);
      if (href) { const a = element('a', files[row[E.file]][0] + (row[E.start] > 0 ? ':' + row[E.start] : ''), 'evidence-source'); a.href = href; li.append(a); }
      else li.append(element('span', '关系暂无可验证来源', 'evidence-source'));
      const details = element('details', undefined, 'relation-context');
      details.append(element('summary', '上下文与置信度'));
      const score = row[E.score];
      details.append(element('p', '提取器置信度：' + (typeof score === 'number' && Number.isFinite(score) ? String(score) : '未提供') + '。此值不是运行期验证结果。'));
      const context = row[E.context];
      details.append(element('pre', context === null || context === undefined || context === '' ? '未记录上下文。' : typeof context === 'string' ? context : JSON.stringify(context, null, 2)));
      li.append(details);
      fragment.append(li);
    });
    $('relations').replaceChildren(fragment);
    const total = n[N.degree] || 0;
    $('relationStatus').textContent = '已加载 ' + number(state.relationRows.length) + ' / ' + number(total) + ' 条关系' + ($('evidence').value ? '，其中 ' + number(rows.length) + ' 条符合证据筛选。继续加载可检查其余关系。' : '。');
    if (!total) $('relationStatus').textContent = '没有已记录的关系；这不证明源码不存在其他连接。';
    $('moreRelations').hidden = state.nextPage >= (n[N.locators] || []).length; $('moreRelations').disabled = state.loading;
  }
  function drawNeighbors() {
    if (state.selected < 0) return; const index = state.selected, n = nodes[index]; state.level = 'detail'; $('mapIntro').hidden = true;
    breadcrumb([{label: modules[n[N.module]] || '外部节点', action: () => focusModule(n[N.module])}, {label: n[N.label], action: () => selectNode(index, false)}]);
    const byNeighbor = new Map(); visibleRelations().forEach(row => { if (row[E.other] !== index && !byNeighbor.has(row[E.other])) byNeighbor.set(row[E.other], row); });
    const items = [{key: 'n' + index, type: 'node', index: index, label: n[N.label], x: 0, y: 0, z: 20, color: '#b8f2f3', size: 24, priority: 100000}];
    const edges = [];
    Array.from(byNeighbor.entries()).slice(0, 40).forEach(([other, row], i) => {
      const angle = i * 2.3999632297, radius = 80 + Math.sqrt(i / 40) * 110;
      items.push({key: 'n' + other, type: 'node', index: other, label: nodes[other][N.label], x: Math.cos(angle) * radius, y: Math.sin(angle) * radius * .8, z: (i % 5 - 2) * 13, color: row[E.evidence] === 'INFERRED' ? '#e6b06b' : '#73c8d5', size: 10, priority: 40 - i});
      edges.push({source: 'n' + index, target: 'n' + other, inferred: row[E.evidence] === 'INFERRED'});
    });
    scene.setData({items: items, edges: edges});
    $('sceneCount').textContent = Math.max(0, items.length - 1) + ' 个邻居 · 已载 ' + state.relationRows.length + ' 条关系';
    if (byNeighbor.size > 40) note('图中显示 40 / ' + byNeighbor.size + ' 个已加载邻居。右侧关系列表保留全部已加载记录。', false); else note('', false);
  }
  scene = global.GXAtlasScene.create({
    host: $('stage'), labels: $('labels'), tooltip: $('tooltip'), reducedMotion: state.reduced,
    onSelect: item => { if (item.type === 'module') focusModule(item.index); else if (item.type === 'file') focusFile(item.index); else selectNode(item.index, true); },
    onModeChange: info => {
      $('renderMode').textContent = info.mode === '3d' ? '三维星图' : '二维星图'; $('toggle2d').setAttribute('aria-pressed', String(info.mode === '2d')); $('toggle2d').textContent = info.mode === '2d' ? '尝试三维' : '二维视图';
      if (info.reason && info.reason !== 'manual') {
        const reason = info.reason === 'context-lost' ? '三维显示已中断' : info.reason === 'vendor-missing' ? '三维资源不可用' : '此设备未提供 WebGL';
        $('viewStatus').textContent = reason + '，已切换二维；搜索、关系和来源仍可使用。';
      } else $('viewStatus').textContent = 'Graphify AST · 本地构建快照';
    }
  });
  $('search').addEventListener('input', () => scheduleFilter(false));
  $('module').addEventListener('change', () => { clearSelection(); scheduleFilter(true); });
  $('kind').addEventListener('change', () => scheduleFilter(true));
  $('fileJump').addEventListener('change', () => { if ($('fileJump').value !== '') focusFile(Number($('fileJump').value)); });
  $('clearFilters').addEventListener('click', resetAll);
  $('moreResults').addEventListener('click', () => { const before = state.resultLimit; state.resultLimit += 200; renderResults(); const button = $('results').children[before]?.querySelector('button'); if (button) button.focus({preventScroll: true}); });
  $('moreModules').addEventListener('click', () => { state.moduleExpanded = !state.moduleExpanded; moduleDistribution(); });
  $('moreRelations').addEventListener('click', loadNextRelations); $('retryRelations').addEventListener('click', loadNextRelations);
  $('evidence').addEventListener('change', () => { renderRelations(); drawNeighbors(); });
  $('toggleExplore').addEventListener('click', () => setImmersive(!state.immersive));
  $('toggle2d').addEventListener('click', () => scene.setMode(scene.metrics().mode === '3d' ? '2d' : '3d'));
  $('zoomIn').addEventListener('click', () => scene.zoom(1.2)); $('zoomOut').addEventListener('click', () => scene.zoom(1 / 1.2)); $('resetView').addEventListener('click', () => scene.reset());
  $('showList').addEventListener('click', () => setPanel('list', !$('listPanel').classList.contains('open'), true));
  $('showDetail').addEventListener('click', () => setPanel('detail', !$('detailPanel').classList.contains('open'), true));
  $('closeList').addEventListener('click', () => setPanel('list', false, false)); $('closeDetail').addEventListener('click', () => setPanel('detail', false, false));
  function setHelp(open) {
    if (open) helpReturn = document.activeElement;
    $('helpPanel').hidden = !open; $('helpButton').setAttribute('aria-expanded', String(open));
    $('helpBackdrop').hidden = !open;
    document.querySelectorAll('.topbar,.workspace,.mobile-tabs,.statusbar,.skip').forEach(el => { el.inert = open; });
    if (open) $('helpPanel').focus(); else if (helpReturn) helpReturn.focus();
  }
  $('helpButton').addEventListener('click', () => setHelp($('helpPanel').hidden)); $('closeHelp').addEventListener('click', () => setHelp(false));
  $('helpBackdrop').addEventListener('click', () => setHelp(false));
  function reduce(value) { state.reduced = value; $('reduceMotion').checked = value; scene.setReducedMotion(value); }
  $('reduceMotion').addEventListener('change', () => reduce($('reduceMotion').checked)); mediaMotion.addEventListener('change', event => reduce(event.matches));
  document.addEventListener('keydown', event => {
    if (!$('helpPanel').hidden) {
      if (event.key === 'Escape') { event.preventDefault(); setHelp(false); return; }
      if (event.key === 'Tab') {
        const targets = Array.from($('helpPanel').querySelectorAll('button,input,a,select')); const first = targets[0], last = targets[targets.length - 1];
        if (event.shiftKey && (document.activeElement === first || document.activeElement === $('helpPanel'))) { last.focus(); event.preventDefault(); }
        else if (!event.shiftKey && document.activeElement === last) { first.focus(); event.preventDefault(); }
      } return;
    }
    if (event.key === '/' && !/INPUT|TEXTAREA|SELECT/.test(event.target.tagName)) { event.preventDefault(); $('search').focus(); }
    if (event.key === 'Escape') {
      if (mediaMedium.matches && $('detailPanel').classList.contains('open')) setPanel('detail', false, false);
      else if (mediaNarrow.matches && $('listPanel').classList.contains('open')) setPanel('list', false, false);
      else if (state.immersive) { setImmersive(false); $('toggleExplore').focus(); }
    }
  });
  function fromHash() {
    let id; try { id = decodeURIComponent(location.hash.slice(1)); } catch (_) { note('节点链接无效。可以搜索符号重新定位。', true); return; }
    if (id && byId.has(id)) selectNode(byId.get(id), false);
    else if (id) note('当前目录中没有此节点。可以搜索符号或返回源码全景。', true);
    else { state.selected = -1; $('nodeInfo').hidden = true; $('overviewInfo').hidden = false; drawOverview(); }
  }
  addEventListener('popstate', fromHash);
  $('alternateView').textContent = document.body.dataset.view === 'detail' ? '返回源码全景' : '一跳关系视图';
  $('alternateView').href = document.body.dataset.view === 'detail' ? 'overview.html' : 'detail.html';
  moduleDistribution(); renderResults(); drawOverview(); fromHash();
  requestAnimationFrame(() => { metrics.readyMs = performance.now(); document.body.dataset.ready = 'true'; });
  global.GXAtlas.inspect = function () { return {readyMs: metrics.readyMs, scriptMs: performance.now() - started, filterMs: metrics.filterMs.slice(), filterVersion: metrics.filterVersion, loadedShards: metrics.loadedShards, matched: state.matched.length, selected: state.selected, loadedRelations: state.relationRows.length, nextPage: state.nextPage, counts: stats, scene: scene.metrics()}; };
  global.GXAtlas.measureMotion = duration => scene.animateFor(duration);
  global.GXAtlas.loseContext = () => scene.loseContext();
})(window);
