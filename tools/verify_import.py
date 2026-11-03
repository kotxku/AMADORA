"""Mirror of PandoraImport.m + ModDoctor.m, run on the PC against exported zips to check each pack would load.

Usage: python -I verify_import.py <workdir> <zip>...
Keep in sync with Natives/installer/PandoraImport.m and ModDoctor.m.
"""
import concurrent.futures, hashlib, io, json, os, re, sys, urllib.parse, urllib.request, zipfile

UA = {'User-Agent': 'kotxku/AMADORA'}
BUNDLED_JAVA = {8, 17, 21, 25}
BUILTIN = {'minecraft', 'java', 'fabricloader', 'fabric-loader', 'quilt_loader', 'forge', 'neoforge'}


def fetch(url):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
            return r.read() if r.status == 200 else None
    except Exception:
        return None


def parse(data):
    if data is None:
        return None
    try:
        return json.loads(data)
    except Exception:
        # NSJSONReadingJSON5Allowed: tolerate comments, trailing commas, raw newlines in strings
        text = re.sub(r'//[^\n]*|/\*.*?\*/', '', data.decode('utf-8', 'replace'), flags=re.S)
        text = re.sub(r',(\s*[}\]])', r'\1', text).replace('\n', ' ').replace('\t', ' ')
        try:
            return json.loads(text)
        except Exception:
            return None


def safe(rel):
    return bool(rel) and not rel.startswith('/') and '..' not in rel.split('/')


def scan_jar(data, provides, depends):
    try:
        z = zipfile.ZipFile(io.BytesIO(data))
        meta = parse(z.read('fabric.mod.json'))
    except Exception:
        return
    if not isinstance(meta, dict):
        return
    if isinstance(meta.get('id'), str):
        provides.add(meta['id'])
    provides.update(p for p in meta.get('provides') or [] if isinstance(p, str))
    if isinstance(meta.get('depends'), dict):
        depends.setdefault(meta.get('id') or id(meta), set()).update(meta['depends'].keys())
    for jar in meta.get('jars') or []:
        try:
            scan_jar(z.read(jar['file']), provides, depends)
        except Exception:
            pass


def jar_info(path):
    try:
        return parse(zipfile.ZipFile(path).read('fabric.mod.json')) or {}
    except Exception:
        return {}


def norm(s):
    return re.sub(r'[-_ ]', '', (s or '').lower())


def modrinth_file(project, mc, loaders):
    q = urllib.parse.urlencode({'loaders': loaders, 'game_versions': json.dumps([mc])})
    versions = parse(fetch(f'https://api.modrinth.com/v2/project/{urllib.parse.quote(project)}/version?{q}'))
    if not versions:
        return None
    files = versions[0].get('files') or []
    primary = next((f for f in files if f.get('primary')), files[0] if files else None)
    return primary and primary.get('url')


def find_mod(mod_id, mc, loader):
    loaders = '["quilt","fabric"]' if loader == 'quilt' else '["fabric"]'
    slug = 'fabric-api' if mod_id == 'fabric' else mod_id
    for cand in dict.fromkeys([slug, slug.replace('_', '-')]):
        url = modrinth_file(cand, mc, loaders)
        if url:
            return url
    q = urllib.parse.urlencode({'query': mod_id, 'limit': 10, 'facets': json.dumps([['project_type:mod'], [f'versions:{mc}']])})
    for hit in (parse(fetch(f'https://api.modrinth.com/v2/search?{q}')) or {}).get('hits', []):
        if norm(hit.get('slug')) == norm(slug) or norm(hit.get('title')) == norm(slug):
            url = modrinth_file(hit['project_id'], mc, loaders)
            if url:
                return url
    return None


def download(url, dest, sha1=None):
    data = fetch(url)
    if data is None or (sha1 and hashlib.sha1(data).hexdigest() != sha1.lower()):
        return False
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    open(dest, 'wb').write(data)
    return True


def mod_doctor(game_dir, mc, loader, report):
    if loader not in ('fabric', 'quilt'):
        report.append(f'  Mod Doctor: skipped ({loader})')
        return
    mods = os.path.join(game_dir, 'mods')
    tried, installed, missing = set(), [], []
    for _ in range(5):
        provides, by_mod = set(), {}
        for f in os.listdir(mods) if os.path.isdir(mods) else []:
            data = open(os.path.join(mods, f), 'rb').read() if f.lower().endswith(('.jar', '.jar.disabled')) else None
            if data:
                scan_jar(data, provides, by_mod if f.lower().endswith('.jar') else {})
        try:
            overrides = parse(open(os.path.join(game_dir, 'config', 'fabric_loader_dependencies.json'), 'rb').read()).get('overrides', {})
        except Exception:
            overrides = {}
        for mod_id, rules in overrides.items():
            if mod_id in by_mod and isinstance(rules, dict):
                if isinstance(rules.get('depends'), dict):
                    by_mod[mod_id] = set(rules['depends'])
                by_mod[mod_id] |= set(rules.get('+depends') or {})
                by_mod[mod_id] -= set(rules.get('-depends') or {})
        need = set().union(*by_mod.values()) - provides - BUILTIN - tried
        if not need:
            break
        for mod_id in sorted(need):
            tried.add(mod_id)
            url = find_mod(mod_id, mc, loader)
            if url and download(url, os.path.join(mods, os.path.basename(urllib.parse.unquote(url)))):
                installed.append(mod_id)
            else:
                missing.append(mod_id)
    report.append(f'  Mod Doctor: downloaded {installed or "nothing"}; not found {missing or "none"}')


def expand_mrpacks(game_dir, state, report):
    mods = os.path.join(game_dir, 'mods')
    names = os.listdir(mods) if os.path.isdir(mods) else []
    dis_ids, dis_names, dis_files = set(), set(), set()
    for f in names:
        if f.endswith('.aux.json'):
            c = (parse(open(os.path.join(mods, f), 'rb').read()) or {}).get('disabled_children') or {}
            dis_ids.update(c.get('disabled_ids') or []); dis_names.update(c.get('disabled_names') or []); dis_files.update(c.get('disabled_filenames') or [])
    for f in names:
        if not f.lower().endswith('.mrpack'):
            continue
        pack = zipfile.ZipFile(os.path.join(mods, f))
        index = parse(pack.read('modrinth.index.json'))
        deps = index.get('dependencies', {})
        state['mc'] = state['mc'] or deps.get('minecraft')
        for key in ('fabric-loader', 'quilt-loader', 'forge', 'neoforge'):
            if key in deps:
                if state['loader'] == 'vanilla':
                    state['loader'] = key.split('-')[0]
                state['loader_version'] = state['loader_version'] or deps[key]
                break

        def one(entry):
            rel, urls = entry.get('path'), entry.get('downloads') or []
            if not urls or (entry.get('env') or {}).get('client') == 'unsupported' or not safe(rel) or os.path.basename(rel) in dis_files:
                return 'skip'
            dest = os.path.join(game_dir, rel)
            ok = os.path.exists(dest) or download(urls[0], dest, (entry.get('hashes') or {}).get('sha1'))
            info = jar_info(dest) if ok else {}
            if info.get('id') in dis_ids or info.get('name') in dis_names:
                os.replace(dest, dest + '.disabled')
            return 'ok' if ok else 'fail:' + rel

        with concurrent.futures.ThreadPoolExecutor(8) as pool:
            results = list(pool.map(one, index.get('files', [])))
        added = 0
        for n in pack.namelist():
            for pre in ('overrides/', 'client-overrides/'):
                rel = n[len(pre):] if n.startswith(pre) else None
                if rel and safe(rel) and not n.endswith('/') and not os.path.exists(os.path.join(game_dir, rel)):
                    os.makedirs(os.path.dirname(os.path.join(game_dir, rel)), exist_ok=True)
                    open(os.path.join(game_dir, rel), 'wb').write(pack.read(n)); added += 1
        pack.close()
        os.makedirs(os.path.join(game_dir, 'pandora-modpacks'), exist_ok=True)
        os.replace(os.path.join(mods, f), os.path.join(game_dir, 'pandora-modpacks', f))
        fails = [r for r in results if r.startswith('fail')]
        report.append(f'  {f}: {results.count("ok")} installed, {results.count("skip")} skipped, {len(fails)} failed, {added} overrides added')
        report.extend('    FAILED ' + r[5:] for r in fails)
        disabled = [x for x in os.listdir(mods) if x.endswith('.disabled')]
        if disabled:
            report.append(f'  disabled as in Pandora: {disabled}')


def import_zip(path, workdir):
    report = [os.path.basename(path)]
    z = zipfile.ZipFile(path)
    entries = {}
    for info in z.infolist():
        n = info.filename.replace('\\', '/')
        while n.startswith('./'):
            n = n[2:]
        if n:
            entries[n] = info
    metas = [n for n in entries if n.split('/')[-1] in ('info_v1.json', 'manifest.json')]
    meta_path = min(metas, key=lambda n: n.count('/'), default=None)
    base = meta_path.rsplit('/', 1)[0] if meta_path and '/' in meta_path else ''
    meta = parse(z.read(entries[meta_path])) if meta_path else None
    if meta_path and meta_path.endswith('manifest.json') and not isinstance((meta or {}).get('minecraft'), dict):
        meta, base = None, ''
    state = {'mc': None, 'loader': None, 'loader_version': None}
    if meta and meta_path.endswith('info_v1.json'):
        state.update(mc=meta.get('minecraft_version'), loader=meta.get('loader'))
    elif meta:
        state['mc'] = meta['minecraft'].get('version')
        lid = (meta['minecraft'].get('modLoaders') or [{}])[0].get('id', '')
        if '-' in lid:
            state['loader'], state['loader_version'] = lid.split('-', 1)
    state['loader'] = (state['loader'] or 'vanilla').lower()
    root = base
    for sub in ('.minecraft', 'minecraft', 'overrides'):
        cand = f'{base}/{sub}' if base else sub
        if any(n.startswith(cand + '/') for n in entries):
            root = cand
            break
    if not meta:
        depths = [(i, '/'.join(n.split('/')[:i])) for n in entries for i, c in enumerate(n.split('/')[:-1]) if c in ('mods', 'saves', 'config')]
        if not depths:
            return report + ['  REJECTED: no mods, saves or config folder']
        root = min(depths)[1]
    report.append(f'  format: {"pandora" if meta and meta_path.endswith("info_v1.json") else "curseforge" if meta else "plain"}, root={root!r}, loader={state["loader"]}, mc={state["mc"]}')

    dest = os.path.join(workdir, os.path.basename(path)[:-4])
    prefix = root + '/' if root else ''
    unsafe = extracted = 0
    for n, info in entries.items():
        if not n.startswith(prefix):
            continue
        rel = n[len(prefix):]
        if not safe(rel):
            unsafe += 1
            continue
        # Only mods/ is written to disk here; everything else is just counted
        if rel.startswith('mods/') and not info.is_dir():
            os.makedirs(os.path.dirname(os.path.join(dest, rel)), exist_ok=True)
            with z.open(info) as src, open(os.path.join(dest, rel), 'wb') as out:
                while chunk := src.read(1 << 20):
                    out.write(chunk)
        extracted += 1
    report.append(f'  extracted {extracted} entries ({unsafe} unsafe skipped)')

    expand_mrpacks(dest, state, report)
    mc, loader, lv = state['mc'], state['loader'], state['loader_version']

    manifest = parse(fetch('https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'))
    ver = next((v for v in manifest['versions'] if v['id'] == mc), None) if manifest else None
    java = (parse(fetch(ver['url'])) or {}).get('javaVersion', {}).get('majorVersion') if ver else None
    runtime = min((j for j in BUNDLED_JAVA if java and j >= java), default=None)
    report.append(f'  Minecraft {mc}: {"found" if ver else "NOT IN MOJANG MANIFEST"}, needs Java {java}, bundled runtime {runtime or "NONE"}')

    if loader in ('fabric', 'quilt'):
        meta_base = 'https://meta.fabricmc.net/v2' if loader == 'fabric' else 'https://meta.quiltmc.org/v3'
        if not lv:
            lv = next((l['version'] for l in parse(fetch(meta_base + '/versions/loader')) or [] if l.get('stable', True)), None)
        profile = parse(fetch(f'{meta_base}/versions/loader/{mc}/{lv}/profile/json'))
        report.append(f'  {loader} loader {lv}: profile {"OK -> " + profile["id"] if profile else "MISSING"}')

    mod_doctor(dest, mc, loader, report)
    jars = [f for f in os.listdir(os.path.join(dest, 'mods'))] if os.path.isdir(os.path.join(dest, 'mods')) else []
    report.append(f'  final mods/: {sum(f.endswith(".jar") for f in jars)} jars, {sum(f.endswith(".disabled") for f in jars)} disabled')
    return report


if __name__ == '__main__':
    for zp in sys.argv[2:]:
        print('\n'.join(import_zip(zp, sys.argv[1])), flush=True)
