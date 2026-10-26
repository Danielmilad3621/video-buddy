"""Exercise the real script's selectors through installed yt-dlp, entirely offline; retain all files."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


if sys.argv[1] == '--capture':
    root = Path(os.environ['VB_FORMAT_CASE'])
    (root / 'arguments.json').write_text(json.dumps(sys.argv[2:]))
    sample = root / 'sample.mp4'
    sample.write_text('Local test placeholder, not downloaded media.\n')
    print('yt-dlp: format test (local placeholder)')
    print(sample)
    sys.exit(0)

import yt_dlp

repo, retained = map(Path, sys.argv[1:3])
captured = json.loads(Path(sys.argv[3]).read_text()) if len(sys.argv) > 3 and sys.argv[3] else None
passed = 0


def check(condition, message):
    global passed
    if not condition:
        raise AssertionError(message)
    passed += 1


def script_options(mode, quality, youtube=True):
    root = Path(tempfile.mkdtemp(prefix='selector-', dir=retained))
    env = os.environ.copy()
    env.update(VB_FORMAT_CASE=str(root), VB_FORMAT_PYTHON=sys.executable,
               VB_FORMAT_TEST=str(Path(__file__).resolve()), TMPDIR=str(root),
               VS_VIDEO_QUALITY=quality, PYTHONDONTWRITEBYTECODE='1')
    # Exported functions intercept both network tools even when the script sets PATH.
    # Its cleanup is disabled only in this disposable shell, so every test file is retained.
    harness = '''
yt-dlp() { "$VB_FORMAT_PYTHON" "$VB_FORMAT_TEST" --capture "$@"; }
curl() { printf '{"status":"error"}'; }
rm() { printf 'Retained cleanup target: %s\\n' "$*" >> "$VB_FORMAT_CASE/retained.log"; }
export -f yt-dlp curl rm
exec /bin/bash "$@"
'''
    url = 'https://www.youtube.com/watch?v=SRtAjiCeit4' if youtube else 'https://example.com/video'
    result = subprocess.run(['/bin/bash', '-c', harness, 'format-test',
                             str(repo / 'scripts/cobalt-dl.sh'), url, mode, str(root / 'out')],
                            cwd=root, env=env, text=True, capture_output=True, timeout=15)
    (root / 'script.log').write_text(result.stdout + result.stderr)
    check(result.returncode == 0, f'script failed: {mode}/{quality}: {result.stderr}')
    args = json.loads((root / 'arguments.json').read_text())
    # parse_options processes the actual CLI arguments, including -t mp4 and all -S/-f options.
    options = yt_dlp.parse_options(['--ignore-config', '--no-plugin-dirs', '--no-cache-dir', *args]).ydl_opts
    options.update(quiet=True, no_warnings=True, check_formats=False, cachedir=False)
    return options


def choose(options, formats):
    with yt_dlp.YoutubeDL(options) as downloader:
        info = {'formats': copy.deepcopy(formats)}
        downloader.sort_formats(info)
        selector = downloader.build_format_selector(options['format'])
        return downloader._select_formats(info['formats'], selector)


def stream(identifier, vcodec='none', acodec='none', height=None, drm=False):
    return dict(format_id=identifier, url='https://example.invalid/' + identifier,
                ext='mp4' if vcodec != 'none' else 'm4a', vcodec=vcodec,
                acodec=acodec, height=height, has_drm=drm)


clear = [stream('h264', 'avc1.640028', height=720),
         stream('av1', 'av01.0.08M.08', height=1080), stream('aac', acodec='mp4a.40.2')]
combined = stream('combined', 'avc1.4d401f', 'mp4a.40.2', 360)
uncertain = [stream('maybe-video', 'avc1.640028', height=2160, drm='maybe'),
             stream('protected-video', 'av01.0.12M.08', height=2160, drm=True),
             stream('maybe-audio', acodec='mp4a.40.2', drm='maybe'),
             stream('missing-flag', 'avc1.640028', 'mp4a.40.2', 2160, drm=None)]
for mode, quality in [('audio', ''), ('auto', ''), ('auto', '480'), ('auto', '720'),
                      ('auto', '1080'), ('auto', 'max'), ('auto', 'highest')]:
    options = script_options(mode, quality)
    result = choose(options, clear + uncertain)
    check(bool(result), f'{mode}/{quality}: clear formats were not selected')
    streams = [part for item in result for part in item.get('requested_formats', [item])]
    check(all(item['has_drm'] is False for item in streams), f'{mode}/{quality}: unsafe stream selected')
    if mode == 'auto':
        expected = 'av1' if quality == 'highest' else 'h264'
        check(any(item['format_id'] == expected for item in streams), f'{quality}: codec preference changed')
    fallback = choose(options, [combined, *uncertain])
    check(bool(fallback) and fallback[0]['format_id'] == 'combined', f'{mode}/{quality}: clear fallback failed')
    check(not choose(options, uncertain), f'{mode}/{quality}: unknown/protected-only formats accepted')
    check(not choose(options, [stream('protected-audio', acodec='mp4a.40.2', drm=True)]),
          f'{mode}/{quality}: protected-only audio accepted')
    if captured:
        real = choose(options, captured['formats'])
        check(bool(real), f'{mode}/{quality}: captured response has no selected format')
        parts = [part for item in real for part in item.get('requested_formats', [item])]
        check(all(part.get('has_drm') is False for part in parts), f'{mode}/{quality}: captured unknown format selected')
        print(f"Captured {mode}/{quality or 'default'}: " + '+'.join(part['format_id'] for part in parts))
    other = script_options(mode, quality, youtube=False)
    check('has_drm' not in (other['format'] or ''), f'{mode}/{quality}: other sites were restricted')

print(f'format selection: {passed} checks passed; no network or media downloads')
