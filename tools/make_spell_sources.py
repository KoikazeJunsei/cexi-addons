"""Builds spell_sources.lua for the spelltracker addon: where each spell's scroll comes from, read off BG-Wiki's scroll
item pages, which carry the game's own acquisition tables ("Purchased From", "Dropped from", "Obtained From" quests and
instances). Each row keeps the page it was read from, so every badge the addon shows can be checked.

    python tools/make_spell_sources.py <vanacore gamedata dir> [--out spell_sources.lua] [--limit N] [--cache dir]

The spell list is VanaCore's own `spells.lua` (generated from CatsEyeXI's sql/spell_list.sql), so a row exists for a
spell exactly when the client knows that spell. Trust spells have no scroll and are left out; blue magic is learnt by
fighting the monster that casts it, so it is tagged from that rule rather than from a page that does not exist.

Pages are read once and kept in the cache directory (default: cache under ~/.cache), so a re-run is cheap and a run can
be resumed. Nothing here is invented: a spell whose page has no acquisition table gets no entry, and the addon draws a
"?" badge saying so.
"""
import argparse
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

WIKI = 'https://www.bg-wiki.com/ffxi/'
a_pace = 2.0
UA = 'Mozilla/5.0 (spelltracker-data; +https://github.com/CatsAndBoats/cexi-addons)'

# primary badge order: what a player can act on soonest first
ORDER = ['wizardoll', 'shop', 'ah', 'drop', 'quest', 'bcnm', 'learn']


def strip(s):
    s = re.sub(r'<br\s*/?>', ' / ', s)
    s = re.sub(r'<[^>]+>', '', s)
    return re.sub(r'\s+', ' ', html.unescape(s)).strip()


def tables(t):
    """every <table> block's rows as lists of cell text (MediaWiki tables are regular enough for this)"""
    out = []
    for tb in re.findall(r'<table.*?</table>', t, re.S):
        rows = []
        for tr in re.findall(r'<tr.*?</tr>', tb, re.S):
            cells = [strip(c) for c in re.findall(r'<t[dh][^>]*>(.*?)</t[dh]>', tr, re.S)]
            if cells:
                rows.append(cells)
        if rows:
            out.append(rows)
    return out


def read_spells(path):
    """VanaCore's gamedata spells.lua -> [(id, name, type)] in file order"""
    text = open(path, encoding='utf-8', errors='replace').read()
    rows = []
    for m in re.finditer(r'^\[(\d+)\]=\{(.*)\},$', text, re.M):
        sid, body = int(m.group(1)), m.group(2)
        name = re.search(r'name="((?:[^"\\]|\\.)*)"', body)
        typ = re.search(r'type="([^"]*)"', body)
        if name:
            rows.append((sid, name.group(1), typ.group(1) if typ else ''))
    return rows


SPELL_JOB_LEVELS = {}


def learnable_at_cap(gamedata_dir, sid, cap=75):
    """True when some job learns the spell at or below the cap (the spells a tracker can actually offer)"""
    if not SPELL_JOB_LEVELS:
        text = open(os.path.join(gamedata_dir, 'spells.lua'), encoding='utf-8', errors='replace').read()
        for m in re.finditer(r'^\[(\d+)\]=\{(.*)\},$', text, re.M):
            lv = [int(x) for x in re.findall(r'\[\d+\]=(\d+)', m.group(2))]
            SPELL_JOB_LEVELS[int(m.group(1))] = any(0 < v <= cap for v in lv)
    return SPELL_JOB_LEVELS.get(sid, False)


def fetch(page, cache_dir):
    safe = re.sub(r'[^A-Za-z0-9_.-]', '_', page)
    path = os.path.join(cache_dir, safe + '.html')
    if os.path.exists(path):
        return open(path, encoding='utf-8', errors='replace').read()
    url = WIKI + urllib.parse.quote(page.replace(' ', '_'), safe=':_()')
    body = None
    for attempt in range(6):
        req = urllib.request.Request(url, headers={'User-Agent': UA})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = r.read().decode('utf-8', 'replace')
            break
        except urllib.error.HTTPError as e:
            if e.code == 404:
                open(path, 'w').close()
                return ''
            # a wiki asks a fast reader to slow down (429) and a host can be busy (5xx): wait longer each time
            if e.code in (429, 500, 502, 503, 504) and attempt < 5:
                # Cloudflare's 1015 is a per-IP cooldown: seconds are not enough, it wants minutes of quiet
                wait = 30 * (attempt + 1) if e.code == 429 else 5 * (attempt + 1)
                print('  %s: waiting %ds' % (e.code, wait), file=sys.stderr)
                time.sleep(wait)
                continue
            raise
    if body is None:
        raise RuntimeError('gave up on ' + url)
    open(path, 'w', encoding='utf-8').write(body)
    time.sleep(a_pace)  # be a good guest: the wiki rate-limits a crawler that reads faster than this
    return body


def zone_of(text, kind):
    """The place a note names: 'Hasim / Lower Jeuno - (H-9) / 23,400 Gil' -> 'Lower Jeuno',
    'Coral Sahagin / Sea Serpent Grotto (+2)' -> 'Sea Serpent Grotto'. '' when the note names no place."""
    if kind not in ('shop', 'drop', 'bcnm', 'quest'):
        return ''
    parts = [x.strip() for x in text.split(' / ')]
    if len(parts) < 2:
        return ''
    z = re.sub(r'\s*-\s*\([^)]*\)\s*$', '', parts[1])   # a shop's grid reference
    z = re.sub(r'\s*\(\+\d+\)\s*$', '', z)             # a drop's "(+N more)"
    z = re.sub(r'\s*\(\+\d+\)', '', z)                  # a marker that ended up inside the place
    return z.strip()

def parse(page_html, name):
    """-> (tags, note, tag, zone) for one scroll page. The pages put a caption row above each header row, so the kind is found by
    the header's own cells rather than by the table's first row."""
    tags, bits = [], []
    has_ah = 'AH Listing' in page_html
    kinds = [('shop', r'NPC Name'), ('drop', r'Monster Name'), ('bcnm', r'^Battle Name$'),
             ('quest', r'^Quest$')]
    for rows in tables(page_html):
        for i, row in enumerate(rows):
            for kind, pat in kinds:
                hit = any(re.search(pat, c) for c in row)
                if not hit:
                    continue
                data = [r for r in rows[i + 1:] if len([c for c in r if c]) >= 1]
                if not data:
                    continue
                r = data[0]
                if kind == 'shop':
                    text = ' / '.join(x for x in (r[0], r[1] if len(r) > 1 else '', r[2] if len(r) > 2 else '') if x)
                elif kind == 'drop':
                    text = ' / '.join(x for x in (r[0], r[2] if len(r) > 2 else '', r[3] if len(r) > 3 else '') if x)
                elif kind == 'bcnm':
                    zone_cell = ''
                    for ci, c in enumerate(row):
                        if re.search(r'^Zone$', c) and ci < len(r):
                            zone_cell = r[ci]
                            break
                    if not zone_cell:
                        zone_cell = r[3] if len(r) > 3 else ''
                    text = ' / '.join(x for x in (r[0], zone_cell) if x)
                else:
                    text = r[0]
                if text and (kind, text) not in [(b[0], b[1]) for b in bits]:
                    tags.append(kind)
                    bits.append((kind, text, len(data)))
                break
    if has_ah:
        tags.append('ah')
    if not tags:
        return [], '', '', ''
    tags = [t for t in ORDER if t in tags]
    bits.sort(key=lambda b: ORDER.index(b[0]))
    if not bits:
        return tags, '', tags[0], ''  # an AH-only scroll: the addon's own tag note says what an AH listing means
    # the badge always names the source the note describes, so a spell whose best path is a drop never wears an "AH"
    # label over a monster's name
    kind, text, n = bits[0]
    zone = zone_of(text, kind)
    if n > 1:
        text += ' (+%d)' % (n - 1)
    return tags, text, kind, zone


def lua_quote(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ') + '"'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('gamedata')
    ap.add_argument('--out', default=None)
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--cache', default=os.path.expanduser('~/.cache/spelltracker-wiki'))
    ap.add_argument('--json', default=None, help='also write the parsed rows as JSON (for tests), and resume from one')
    ap.add_argument('--pace', type=float, default=2.0, help='seconds between page reads (default 2: the wiki blocks faster)')
    ap.add_argument('--all', action='store_true', help='read every spell, not only the ones a job learns by the cap')
    a = ap.parse_args()

    global a_pace
    a_pace = a.pace
    os.makedirs(a.cache, exist_ok=True)
    spells = read_spells(os.path.join(a.gamedata, 'spells.lua'))
    if a.limit:
        spells = spells[:a.limit]
    rows, missing, learnt = {}, [], []
    if a.json and os.path.exists(a.json):  # resume: a crawl that hit the wiki's cooldown keeps what it had
        try:
            rows = {int(k): v for k, v in json.load(open(a.json)).items()}
            print('resuming with %d rows' % len(rows), file=sys.stderr)
        except Exception:
            rows = {}
    for i, (sid, name, typ) in enumerate(spells, 1):
        if typ == 'trust':
            continue
        if typ == 'blue':
            # blue magic is learnt by being hit by it, not from a scroll
            rows[sid] = {'tag': 'learn', 'tags': ['learn'],
                         'note': 'learnt by fighting the monster that casts it',
                         'src': WIKI + 'Blue_Magic'}
            learnt.append(sid)
            continue
        if not a.all and not learnable_at_cap(a.gamedata, sid):
            continue  # a spell no job learns by 75 has no acquisition path to show
        if sid in rows:
            continue
        page = None
        page_html = ''
        # three tries at most: the scroll page, a geomancy plate, then the spell's own page. Some spells have no scroll
        # item page but the spell page still carries the same "Purchased From" table (Firestorm, Geohelix), and 67 spells
        # were being dropped as "no page" for that reason alone
        prefixes = ('Scroll_of_', 'Plate_of_', '') if typ == 'geomancy' else ('Scroll_of_', '')
        for prefix in prefixes:
            cand = prefix + name
            body = fetch(cand, a.cache)
            if body:
                page, page_html = cand, body
                break
        if page is None:
            missing.append((sid, name))
            continue
        tags, note, tag, zone = parse(page_html, name)
        if not tags:
            continue
        rows[sid] = {'tag': tag, 'tags': tags, 'note': note, 'zone': zone,
                     'src': WIKI + urllib.parse.quote(page.replace(' ', '_'), safe=':_()')}
        if i % 25 == 0:
            print('  %d/%d (%d rows)' % (i, len(spells), len(rows)), file=sys.stderr)
            if a.json:  # a crash an hour in should not throw the hour away
                json.dump(rows, open(a.json, 'w'), indent=0, sort_keys=True)

    if a.json:
        json.dump(rows, open(a.json, 'w'), indent=0, sort_keys=True)

    out = a.out or os.path.join(os.path.dirname(__file__), '..', 'addons', 'vanacore', 'spelltracker-vanacore',
                                'spell_sources.lua')
    names = {sid: name for sid, name, _ in spells}
    with open(out, 'w', encoding='utf-8') as f:
        f.write('-- Where each spell\'s scroll comes from, read off BG-Wiki\'s scroll item pages (their "Purchased From",\n')
        f.write('-- "Dropped from" and "Obtained From" tables) by tools/make_spell_sources.py on %s.\n'
                % time.strftime('%Y-%m-%d'))
        f.write('-- Keyed by spell id, the same ids as vana.gamedata.spells. Each row keeps the page it was read from in\n')
        f.write('-- `src`, so every badge can be checked. Blue magic is tagged from the rule that it is learnt in battle.\n')
        f.write('-- A spell with no row has no recorded source: the addon draws a "?" badge rather than a guess.\n')
        f.write('-- %d spells with a source, %d without a scroll page. Don\'t edit: rerun the generator.\n' % (len(rows), len(missing)))
        f.write('local M = {}\n\nM.spells = {\n')
        for sid in sorted(rows):
            r = rows[sid]
            taglist = ','.join(lua_quote(t) for t in r['tags'])
            f.write('[%d]={tag=%s,tags={%s},note=%s,zone=%s,src=%s}, -- %s\n'
                    % (sid, lua_quote(r['tag']), taglist, lua_quote(r['note']), lua_quote(r.get('zone', '')),
                       lua_quote(r['src']), names.get(sid, '')))
        f.write('}\n\nreturn M\n')
    print('wrote %s: %d rows, %d spells with no scroll page' % (out, len(rows), len(missing)))
    if missing:
        print('no page (first 10): %s' % ', '.join(n for _, n in missing[:10]))


if __name__ == '__main__':
    main()
