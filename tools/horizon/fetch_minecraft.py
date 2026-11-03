"""Downloads the Minecraft jars Horizon's research-lock.json pins, for compiling Horizon's exporter
classes in CI only (build_prepare_root.sh): the version JSON, client and server jars, and every
library jar in Mojang's layout. None of it is shipped.

Usage: fetch_minecraft.py <research-lock.json> <output folder>
"""
import hashlib
import json
import os
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor


def fetch(url, path, sha1=None):
    if os.path.isfile(path) and (sha1 is None or digest(path) == sha1):
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=120) as response, open(path + '.part', 'wb') as out:
                while chunk := response.read(1 << 20):
                    out.write(chunk)
            if sha1 and digest(path + '.part') != sha1:
                raise ValueError(f'{url}: SHA-1 mismatch')
            os.replace(path + '.part', path)
            return
        except Exception:
            if attempt == 2:
                raise


def digest(path):
    h = hashlib.sha1()
    with open(path, 'rb') as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def main(lock_path, out):
    pin = json.load(open(lock_path, encoding='utf-8'))['minecraft']
    version_json = os.path.join(out, 'version.json')
    fetch(f"https://piston-meta.mojang.com/v1/packages/{pin['manifest_sha1']}/{pin['version']}.json",
          version_json, pin['manifest_sha1'])
    manifest = json.load(open(version_json, encoding='utf-8'))
    jobs = [(manifest['downloads']['client']['url'], os.path.join(out, 'client.jar'), pin['client_sha1']),
            (manifest['downloads']['server']['url'], os.path.join(out, 'server.jar'), pin['server_sha1'])]
    for library in manifest['libraries']:
        artifact = library.get('downloads', {}).get('artifact')
        if artifact and '..' not in artifact['path']:
            jobs.append((artifact['url'], os.path.join(out, 'libraries', artifact['path']), artifact.get('sha1')))
    with ThreadPoolExecutor(8) as pool:
        list(pool.map(lambda job: fetch(*job), jobs))
    print(f"Fetched Minecraft {pin['version']}: {len(jobs)} files")


if __name__ == '__main__':
    main(*sys.argv[1:3])
