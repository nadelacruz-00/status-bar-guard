#!/usr/bin/env python3
"""Inline app.css / app.js into a single self-contained index.html (dist/).

The WebUI lists apps by package name and derives user/system from `pm` on the
device, so there is no pre-built metadata to inline: the build is fully
reproducible from the repo alone.
"""
import os, re

HERE = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(HERE, 'dist')
os.makedirs(DIST, exist_ok=True)


def read(name):
    with open(os.path.join(HERE, name), encoding='utf-8') as f:
        return f.read()


html = read('index.html')
css = read('app.css')
js = read('app.js')

# styles: replace <link rel=stylesheet ...> with inline <style>
html = re.sub(r'<link rel="stylesheet" href="app\.css">', '<style>\n' + css + '\n</style>', html)

# script: replace <script src="app.js"></script> with inline <script>
html = html.replace('<script src="app.js"></script>', '<script>\n' + js + '\n</script>')

out = os.path.join(DIST, 'index.html')
with open(out, 'w', encoding='utf-8') as f:
    f.write(html)
print('built', out, f'{os.path.getsize(out)/1024:.0f} KB')
assert 'src="app.js"' not in html and 'href="app.css"' not in html, 'inlining failed'
print('inlined ok · css:', len(css), 'js:', len(js))
