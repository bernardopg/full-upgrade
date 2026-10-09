"""Offline GitHub transport for Artcraft tests; production has no test URL override."""
import io
import os
from pathlib import Path
import urllib.error
import urllib.request

fixtures = os.environ.get('ARTCRAFT_FIXTURES')
if fixtures:
    def urlopen(request, **_kwargs):
        url = request.full_url
        root = Path(fixtures)
        with (root / 'requests').open('a') as log:
            log.write(url + '\n')
        if url.startswith('https://api.github.com/repos/storytold/'):
            app = url.split('/')[5]
            path = root / (app + '.json')
        elif url.startswith('https://github.com/storytold/'):
            app = url.split('/')[4]
            path = root / (app + '.tar.gz' if url.endswith('.tar.gz') else app + '.sums')
        else:
            raise urllib.error.URLError('unexpected test URL')
        if not path.exists():
            raise urllib.error.URLError('fixture offline')
        return io.BytesIO(path.read_bytes())
    urllib.request.urlopen = urlopen
