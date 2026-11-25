"""Builds dice_data.lua for the spelltracker addon: where each corsair die comes from, read off BG-Wiki's die item
pages, which carry the same acquisition tables the scroll pages do ("Purchased From", "Dropped from", "Obtained
From"). Every row keeps the page it was read from, so each badge the addon shows can be checked.

    python tools/make_dice_sources.py <vanacore gamedata dir> [--out dice_data.lua] [--limit N] [--cache dir]

The dice are VanaCore's own item table (`items_*.lua`, the items whose `ah_name` is "dice": ids 5477-5505 plus 6368
Geomancer Die and 6369 Rune Fencer Die), and the COR level each one asks for is the "COR Lv.<n>" its description
prints. The roll it teaches is the name in that description, resolved to exactly one ability in `abilities.lua` whose
job is COR (17) - that is the ability id the addon reads known-status for out of vana.game.abilities().

Nothing here is invented: a die whose page has no acquisition table gets tag "none" and the addon draws its neutral
badge, and a die whose page could not be read gets no row at all and is named in the summary.

This module imports make_spell_sources and reuses its table parsers, its zone reader and its fetch (so the same page
cache under ~/.cache/spelltracker-wiki serves both crawlers and the same 2 s pacing keeps the wiki happy). It does not
copy them: one crawler, one politeness policy, one on-disk cache.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import make_spell_sources as M  # noqa: E402  (the parser, the zone reader, the cached fetch, the pacing)

DICE_AH_NAME = 'dice'
# a die's own page is '<Name> Die' with the wiki's underscores; the fallback is the roll's page, which on a few dice
# carries the same tables (the wiki has a page per roll too, and it is the die's own page that is authoritative)
ORDER = M.ORDER


def strip_esc(s):
    """a Lua string literal's escapes -> the text: only the ones the generated tables use (\\\\ \\" \\n)"""
    return s.replace('\\\\n', '\n').replace('\\n', ' ').replace('\\"', '"').replace('\\\\', '\\')


def read_dice(gamedata_dir):
    """every item whose ah_name is 'dice' -> [{id,name,roll,level,sell}] in id order"""
    out = []
    for fn in sorted(os.listdir(gamedata_dir)):
        if not re.match(r'items_\d+\.lua$', fn):
            continue
        text = open(os.path.join(gamedata_dir, fn), encoding='utf-8', errors='replace').read()
        for m in re.finditer(r'^\[(\d+)\]=\{(.*)\},$', text, re.M):
            iid, body = int(m.group(1)), m.group(2)
            if ('ah_name="%s"' % DICE_AH_NAME) not in body:
                continue
            name = re.search(r'name="((?:[^"\\]|\\.)*)"', body)
            desc = re.search(r'description="((?:[^"\\]|\\.)*)"', body)
            sell = re.search(r'base_sell=(\d+)', body)
            if name is None or desc is None:
                continue
            text_desc = strip_esc(desc.group(1))
            lv = re.search(r'COR Lv\.(\d+)', text_desc)
            roll = re.search(r'Teaches the Phantom Roll ability\s+"([^"\n]+)', text_desc)
            if lv is None or roll is None:
                continue
            out.append({
                'id': iid,
                'name': strip_esc(name.group(1)),
                'roll': roll.group(1).strip().rstrip('.').strip(),
                'level': int(lv.group(1)),
                'sell': int(sell.group(1)) if sell else 0,
            })
    out.sort(key=lambda r: r['id'])
    return out


def read_abilities(gamedata_dir):
    """the COR (job 17) abilities -> {name: (id, level)}. The roll a die teaches is one of these."""
    text = open(os.path.join(gamedata_dir, 'abilities.lua'), encoding='utf-8', errors='replace').read()
    out = {}
    for m in re.finditer(r'^\[(\d+)\]=\{(.*)\},$', text, re.M):
        aid, body = int(m.group(1)), m.group(2)
        if 'job_name="COR"' not in body:
            continue
        name = re.search(r'name="((?:[^"\\]|\\.)*)"', body)
        lv = re.search(r'level=(\d+)', body)
        if name and lv:
            out[strip_esc(name.group(1))] = (aid, int(lv.group(1)))
    return out


def page_of(name):
    """the BG-Wiki page slug: spaces become underscores and nothing else changes ('Bolter's_Die' keeps its
    apostrophe; fetch() percent-encodes it for the request and the cache keeps the slug as the file name)"""
    return name.replace(' ', '_')


def has_ah_listing(page_html):
    """Does the page carry an AH listing at all. The die pages print 'AH  Listing:' with two spaces inside the bold
    cell where a scroll page prints 'AH Listing', so the scroll parser's own substring test misses every die: this
    one asks the question with whitespace allowed, and the same 'ah' tag goes on the row."""
    return re.search(r'AH\s+Listing', page_html) is not None


def parse_die(page_html, name):
    """-> tags, note, tag, zone for one die page. The tables come from the scroll crawler's own parse() so both
    writers read a 'Purchased From' table the same way; the AH question is asked again here (see has_ah_listing)."""
    tags, note, tag, zone = M.parse(page_html, name)
    if has_ah_listing(page_html) and 'ah' not in tags:
        tags.append('ah')
    if not tags:
        return [], '', 'none', ''
    tags = [t for t in ORDER if t in tags]
    if tag == '' or tag is None:
        # an AH-only page: the row's note is empty on purpose (an AH listing names no place and no price)
        tag = tags[0]
    return tags, note, tag, zone


def lua_quote(s):
    return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ') + '"'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('gamedata')
    ap.add_argument('--out', default=None)
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--cache', default=os.path.expanduser('~/.cache/spelltracker-wiki'))
    ap.add_argument('--json', default=None, help='also write the parsed rows as JSON (for tests), and resume from one')
    ap.add_argument('--pace', type=float, default=2.0, help='seconds between page reads (default 2: the wiki blocks faster)')
    a = ap.parse_args()

    M.a_pace = a.pace
    os.makedirs(a.cache, exist_ok=True)

    dice = read_dice(a.gamedata)
    abilities = read_abilities(a.gamedata)
    if a.limit:
        dice = dice[:a.limit]

    rows, missing, blocked, unresolved = {}, [], [], []
    if a.json and os.path.exists(a.json):  # resume: a crawl that hit the wiki's cooldown keeps what it had
        try:
            rows = {int(k): v for k, v in json.load(open(a.json)).items()}
            print('resuming with %d rows' % len(rows), file=sys.stderr)
        except Exception:
            rows = {}

    for i, die in enumerate(dice, 1):
        hit = abilities.get(die['roll'])
        if hit is None:
            # a die teaching a roll the ability table does not have: no ability id, so no known-status to read.
            # Reported, never guessed.
            unresolved.append((die['id'], die['name'], die['roll']))
            continue
        die['ability_id'], die['ability_level'] = hit
        if die['id'] in rows:
            continue
        page = page_of(die['name'])
        try:
            page_html = M.fetch(page, a.cache)
        except Exception as e:  # 429 / Cloudflare 1015 / 5xx after the crawler's own backoff: stop, do not hammer
            print('  blocked on %s: %s - stopping the crawl here' % (page, e), file=sys.stderr)
            blocked.append((die['id'], die['name']))
            break
        if not page_html:
            missing.append((die['id'], die['name']))
            continue
        tags, note, tag, zone = parse_die(page_html, die['name'])
        rows[die['id']] = {
            'name': die['name'], 'roll': die['roll'], 'ability_id': die['ability_id'],
            'level': die['level'], 'tag': tag, 'tags': tags, 'note': note, 'zone': zone,
            'src': M.WIKI + urllib.parse.quote(page, safe=':_()'),
        }
        if i % 10 == 0:
            print('  %d/%d (%d rows)' % (i, len(dice), len(rows)), file=sys.stderr)
            if a.json:  # a crash a few pages in should not throw the crawl away
                json.dump(rows, open(a.json, 'w'), indent=0, sort_keys=True)

    if a.json:
        json.dump(rows, open(a.json, 'w'), indent=0, sort_keys=True)

    out = a.out or os.path.join(HERE, '..', 'addons', 'vanacore', 'spelltracker-vanacore', 'dice_data.lua')
    names = {d['id']: d['name'] for d in dice}
    kinds = {}
    for r in rows.values():
        kinds[r['tag']] = kinds.get(r['tag'], 0) + 1
    zones = sum(1 for r in rows.values() if r.get('zone'))
    with open(out, 'w', encoding='utf-8') as f:
        f.write("-- Where each corsair die is bought or found, read off BG-Wiki's die item pages (their \"Purchased\n")
        f.write('-- From\", \"Dropped from\" and \"Obtained From\" tables) by tools/make_dice_sources.py on %s.\n'
                % time.strftime('%Y-%m-%d'))
        f.write('-- Keyed by die item id, the same ids as vana.gamedata.items. Each row keeps the page it was read from\n')
        f.write('-- in `src`, so every badge can be checked. `level` is the COR level the die\'s own description asks\n')
        f.write('-- for; `ability_id` is the Phantom Roll ability it teaches, which is what known-status is read for\n')
        f.write('-- out of vana.game.abilities(). A die with tag "none" has a page that names no source: the addon draws\n')
        f.write('-- its neutral badge rather than a guess. Don\'t edit: rerun the generator.\n')
        f.write('-- %d dice with a row, %d of them naming a place, %d without a page. Don\'t edit: rerun the generator.\n'
                % (len(rows), zones, len(missing)))
        f.write('local M = {}\n\nM.dice = {\n')
        for iid in sorted(rows):
            r = rows[iid]
            taglist = ','.join(lua_quote(t) for t in r['tags'])
            f.write('[%d]={id=%d,name=%s,roll=%s,ability_id=%d,level=%d,tag=%s,tags={%s},note=%s,zone=%s,src=%s}, -- %s\n'
                    % (iid, iid, lua_quote(r['name']), lua_quote(r['roll']), r['ability_id'], r['level'],
                       lua_quote(r['tag']), taglist, lua_quote(r['note']), lua_quote(r.get('zone', '')),
                       lua_quote(r['src']), names.get(iid, '')))
        f.write('}\n\nreturn M\n')
    print('wrote %s: %d rows, %d with a zone, %d with no page, %d unresolved'
          % (out, len(rows), zones, len(missing), len(unresolved)))
    print('by kind: %s' % ', '.join('%s %d' % (k, kinds[k]) for k in sorted(kinds)))
    if missing:
        print('no page: %s' % ', '.join('%s (%d)' % (n, i) for i, n in missing))
    if unresolved:
        print('no COR ability: %s' % ', '.join('%s (%d)' % (n, i) for i, n, _ in unresolved))
    if blocked:
        print('crawl stopped at: %s' % ', '.join('%s (%d)' % (n, i) for i, n in blocked))


if __name__ == '__main__':
    main()
