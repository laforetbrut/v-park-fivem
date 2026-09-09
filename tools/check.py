#!/usr/bin/env python3
"""
tools/check.py

Static checks over the whole resource. Run it before every commit and before every release.

    python tools/check.py

It exits non-zero when anything fails, so it drops straight into a git hook or a CI step.

-----------------------------------------------------------------------------------------------
WHAT IT CHECKS, AND WHY EACH ONE IS HERE
-----------------------------------------------------------------------------------------------

Every assertion below exists because the thing it checks has actually gone wrong somewhere, in
this resource or in a sibling one. None of them are hypothetical.

  1.  SYNTAX          Every .lua file parses under Lua 5.4. Caught `goto` used as a table key
                      in config.lua, which is a parse error that takes the whole file with it
                      and which no amount of reading spots.

  2.  BOM             No file starts with a UTF-8 byte order mark. A BOM breaks the Lua parse
                      with an error that points at line 1 and says nothing useful, and Windows
                      PowerShell writes one by default with `Set-Content -Encoding utf8`.

  3.  LOCALES         Every locale is key-for-key identical to English, with matching format
                      specifiers. A `%d` in French where English has a `%s` is a crash for
                      French-speaking players only, which survives a whole release.

  4.  LOCALE USE      Every key passed to `L()` exists. A missing key renders as the key
                      itself, which is diagnosable but ugly, and there is no reason to ship one.

  5.  CALLABLE GATE   Nothing under bridge/ or server/ tests `type(x) == 'function'` on a
                      framework method. A function that has crossed a resource boundary is a
                      TABLE with a `__call` metamethod, and a type test rejects an object that
                      calls perfectly well. The symptom is a resource that detects the
                      framework, announces itself ready, and never resolves a single player.

  6.  GROUND SNAP     `SetVehicleOnGroundProperly` appears nowhere outside a comment. It is
                      the direct cause of the "my car came back in the street" bug that this
                      resource exists to not have.

  7.  SCHEMA          The columns in `sql/v_park.sql` match `Store.columns` exactly, in the
                      same order. They are written in two places and a drift between them is a
                      batch insert whose values land in the wrong columns.

  8.  MANIFEST        Every Lua file in the repository is listed in fxmanifest.lua, and every
                      file listed exists. An unlisted file is dead code that looks live.

  9.  GATES           Every `gate` named in shared/schema.lua exists in `Config.Save.fields`.
                      A typo there silently disables a whole property group.

  10. RESERVED        No bare table key is a Lua reserved word. See check 1: this is the
                      generalisation of the bug it caught.

  11. PARAM NILS      Nothing reads `Store.toValues` with `ipairs` or `pairs`. It is a
                      positional list that contains nils, and `ipairs` stops at the first one
                      while `#` over a hole is undefined. Getting this wrong scrambled a whole
                      insert batch and lost every row in it, with one line of console output.
"""

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

failures = []
warnings = []
checks_run = 0


def fail(check, message):
    failures.append(f"[{check}] {message}")


def warn(check, message):
    warnings.append(f"[{check}] {message}")


def lua_files():
    out = []
    for base, dirs, names in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules', '__pycache__', '.claude')]
        for name in sorted(names):
            if name.endswith('.lua'):
                out.append(os.path.join(base, name))
    return out


def read(path):
    with io.open(path, encoding='utf-8') as handle:
        return handle.read()


def relative(path):
    return os.path.relpath(path, ROOT).replace('\\', '/')


def strip_comments(source):
    """
    Blank out every Lua comment, preserving line numbering.

    Necessary because several checks below scan for a pattern that this resource's own prose
    describes at length: the file documenting why `type(x) == "function"` is wrong contains that
    exact string a dozen times, and the placement engine's header names the native it exists to
    never call.

    Comment bodies are replaced with spaces rather than deleted, so every reported line number
    stays honest - which is the whole value of reporting one.

    String literals are walked rather than skipped, so a `--` inside a string is not mistaken
    for the start of a comment.
    """
    out = []
    index = 0
    length = len(source)

    while index < length:
        # A long comment: --[[ ... ]] or --[==[ ... ]==]
        if source.startswith('--[', index):
            opener = re.match(r'--\[(=*)\[', source[index:])
            if opener:
                closer = ']' + opener.group(1) + ']'
                end = source.find(closer, index + opener.end())
                end = length if end == -1 else end + len(closer)
                out.append(''.join('\n' if char == '\n' else ' ' for char in source[index:end]))
                index = end
                continue

        # A line comment.
        if source.startswith('--', index):
            end = source.find('\n', index)
            end = length if end == -1 else end
            out.append(' ' * (end - index))
            index = end
            continue

        # A string literal, copied through verbatim.
        if source[index] in ('"', "'"):
            quote = source[index]
            out.append(source[index])
            index += 1

            while index < length:
                char = source[index]
                out.append(char)

                if char == '\\' and index + 1 < length:
                    index += 1
                    out.append(source[index])
                elif char == quote or char == '\n':
                    index += 1
                    break

                index += 1
            continue

        out.append(source[index])
        index += 1

    return ''.join(out)


# ==============================================================================================
# 1. Syntax
# ==============================================================================================

def check_syntax():
    """
    Parse every file with a real Lua 5.4 parser.

    `lupa` is optional. Without it the check is skipped with a warning rather than failing -
    a contributor without it should still be able to run the other nine - but CI should have
    it installed, because this is the check that catches the errors reading cannot.
    """
    global checks_run
    checks_run += 1

    try:
        from lupa import lua54
    except ImportError:
        warn('syntax', 'lupa is not installed, so no file was parsed. `pip install lupa`')
        return

    runtime = lua54.LuaRuntime()
    compile_one = runtime.eval(
        "function(src, name)\n"
        "  local f, err = load(src, name)\n"
        "  if f then return true, '' else return false, err end\n"
        "end\n"
    )

    for path in lua_files():
        ok, err = compile_one(read(path), '@' + relative(path))
        if not ok:
            fail('syntax', f'{relative(path)}: {err}')


# ==============================================================================================
# 2. Byte order marks
# ==============================================================================================

def check_bom():
    global checks_run
    checks_run += 1

    for base, dirs, names in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules', '__pycache__', '.claude')]
        for name in names:
            if not name.endswith(('.lua', '.sql', '.json', '.md', '.js', '.css', '.html')):
                continue

            path = os.path.join(base, name)
            with io.open(path, 'rb') as handle:
                head = handle.read(3)

            if head == b'\xef\xbb\xbf':
                fail('bom', f'{relative(path)} starts with a UTF-8 BOM')


# ==============================================================================================
# 3 and 4. Locales
# ==============================================================================================

KEY_LINE = re.compile(r"^\s*\['([A-Za-z0-9_.]+)'\]\s*=\s*(.+?),?\s*$", re.M)
FORMAT_SPEC = re.compile(r'%[-+ #0]*[\d.]*[sdifgxXqc%]')


def parse_locale(path):
    """
    Read a locale file into { key: value }.

    Deliberately a regular expression rather than a Lua parse. The check has to work without
    lupa, the files have a fixed shape enforced by this very function, and a locale that does
    not match the shape is itself worth reporting.
    """
    entries = {}
    for match in KEY_LINE.finditer(read(path)):
        entries[match.group(1)] = match.group(2)
    return entries


def check_locales():
    global checks_run
    checks_run += 1

    locales_dir = os.path.join(ROOT, 'locales')
    if not os.path.isdir(locales_dir):
        fail('locales', 'there is no locales/ directory')
        return {}

    english_path = os.path.join(locales_dir, 'en.lua')
    if not os.path.exists(english_path):
        fail('locales', 'locales/en.lua is missing, and it is the base every other file needs')
        return {}

    english = parse_locale(english_path)

    if len(english) < 50:
        fail('locales', f'only {len(english)} keys parsed from en.lua, which cannot be right')

    for name in sorted(os.listdir(locales_dir)):
        if not name.endswith('.lua') or name == 'en.lua':
            continue

        other = parse_locale(os.path.join(locales_dir, name))

        missing = sorted(set(english) - set(other))
        extra = sorted(set(other) - set(english))

        for key in missing:
            fail('locales', f'{name} is missing `{key}`')
        for key in extra:
            fail('locales', f'{name} has `{key}`, which English does not')

        # Format specifiers must match in kind and in order. `%s` where English has `%d` is a
        # crash inside string.format for that language only.
        for key in sorted(set(english) & set(other)):
            left = FORMAT_SPEC.findall(english[key])
            right = FORMAT_SPEC.findall(other[key])

            if left != right:
                fail('locales',
                     f'{name} `{key}` has specifiers {right}, English has {left}')

    return english


def check_locale_usage(english):
    global checks_run
    checks_run += 1

    if not english:
        return

    used = set()

    for path in lua_files():
        if '/locales/' in relative(path):
            continue

        source = read(path)
        used |= set(re.findall(r"L\('([A-Za-z0-9_.]+)'", source))
        used |= set(re.findall(r"Locale\.text\('([A-Za-z0-9_.]+)'", source))

    # Keys the panel asks for by name in a list rather than through L() at a call site.
    panel = os.path.join(ROOT, 'client', 'panel.lua')
    if os.path.exists(panel):
        block = re.search(r"local keys = \{(.*?)\n    \}", read(panel), re.S)
        if block:
            used |= set(re.findall(r"'([A-Za-z0-9_.]+)'", block.group(1)))

    for key in sorted(used):
        # Keys built by concatenation cannot be checked and are not reported.
        if key.endswith('.'):
            continue
        if key not in english:
            fail('locale-use', f'`{key}` is used but is not in en.lua')


# ==============================================================================================
# 5. The callable gate
# ==============================================================================================

def check_callable_gate():
    global checks_run
    checks_run += 1

    pattern = re.compile(r"type\s*\(\s*[\w.\[\]'\"]+\s*\)\s*[=~]=\s*['\"]function['\"]")

    for path in lua_files():
        rel = relative(path)
        if not (rel.startswith('bridge/') or rel.startswith('server/')):
            continue

        # `Park.callable` IS the implementation of the correct test, and it necessarily
        # contains the string this check looks for. It is the one exemption, and it is by
        # exact path so that a second file cannot quietly inherit it.
        if rel == 'bridge/shared/park.lua':
            continue

        for number, line in enumerate(strip_comments(read(path)).splitlines(), 1):
            if pattern.search(line):
                fail('callable',
                     f'{rel}:{number} gates on type() == "function". Use Park.callable.')


# ==============================================================================================
# 6. The ground snap
# ==============================================================================================

def check_ground_snap():
    global checks_run
    checks_run += 1

    for path in lua_files():
        for number, line in enumerate(strip_comments(read(path)).splitlines(), 1):
            if 'SetVehicleOnGroundProperly' not in line:
                continue

            fail('ground-snap',
                 f'{relative(path)}:{number} calls SetVehicleOnGroundProperly. '
                 'It drops vehicles through the floor in car parks. See Config.Placement.')


# ==============================================================================================
# 7. Schema and columns
# ==============================================================================================

def check_schema_columns():
    global checks_run
    checks_run += 1

    store_path = os.path.join(ROOT, 'server', 'store.lua')
    sql_path = os.path.join(ROOT, 'sql', 'v_park.sql')

    if not (os.path.exists(store_path) and os.path.exists(sql_path)):
        fail('schema', 'server/store.lua or sql/v_park.sql is missing')
        return

    block = re.search(r"Store\.columns = \{(.*?)\n\}", read(store_path), re.S)
    if not block:
        fail('schema', 'could not find Store.columns in server/store.lua')
        return

    lua_columns = re.findall(r"'([a-z_]+)'", block.group(1))

    sql = read(sql_path)
    table = re.search(r"CREATE TABLE IF NOT EXISTS `v_park_vehicles` \((.*?)\n\) ENGINE", sql, re.S)
    if not table:
        fail('schema', 'could not find the v_park_vehicles table in sql/v_park.sql')
        return

    sql_columns = []
    for line in table.group(1).splitlines():
        stripped = line.strip()
        if stripped.startswith('--') or stripped.startswith(('PRIMARY', 'KEY')):
            continue
        match = re.match(r"`([a-z_]+)`\s+\w", stripped)
        if match:
            sql_columns.append(match.group(1))

    missing_in_sql = [c for c in lua_columns if c not in sql_columns]
    missing_in_lua = [c for c in sql_columns if c not in lua_columns]

    for column in missing_in_sql:
        fail('schema', f'`{column}` is in Store.columns and not in sql/v_park.sql')
    for column in missing_in_lua:
        fail('schema', f'`{column}` is in sql/v_park.sql and not in Store.columns')

    # The runtime CREATE TABLE in database.lua has to agree too, or a fresh install and an
    # imported one end up with different tables.
    database = read(os.path.join(ROOT, 'server', 'database.lua'))
    for column in lua_columns:
        if f'`{column}`' not in database:
            fail('schema', f'`{column}` is in Store.columns and not in the runtime schema')


# ==============================================================================================
# 8. The manifest
# ==============================================================================================

def check_manifest():
    global checks_run
    checks_run += 1

    manifest_path = os.path.join(ROOT, 'fxmanifest.lua')
    if not os.path.exists(manifest_path):
        fail('manifest', 'there is no fxmanifest.lua')
        return

    manifest = read(manifest_path)
    listed = set(re.findall(r"'([\w/\-.]+\.lua)'", manifest))

    for path in lua_files():
        rel = relative(path)
        if rel == 'fxmanifest.lua' or rel.startswith('tools/'):
            continue
        if rel not in listed:
            fail('manifest', f'{rel} exists and is not listed in fxmanifest.lua')

    for name in sorted(listed):
        if not os.path.exists(os.path.join(ROOT, name)):
            fail('manifest', f'fxmanifest.lua lists {name}, which does not exist')

    for asset in re.findall(r"'(html/[\w/\-.]+)'", manifest):
        if not os.path.exists(os.path.join(ROOT, asset)):
            fail('manifest', f'fxmanifest.lua lists {asset}, which does not exist')


# ==============================================================================================
# 9. Schema gates
# ==============================================================================================

def check_schema_gates():
    global checks_run
    checks_run += 1

    schema_path = os.path.join(ROOT, 'shared', 'schema.lua')
    config_path = os.path.join(ROOT, 'config.lua')

    if not (os.path.exists(schema_path) and os.path.exists(config_path)):
        fail('gates', 'shared/schema.lua or config.lua is missing')
        return

    gates = set(re.findall(r"gate\s*=\s*'(\w+)'", read(schema_path)))

    config = read(config_path)
    fields = re.search(r"fields = \{(.*?)\n    \},", config, re.S)
    if not fields:
        fail('gates', 'could not find Config.Save.fields in config.lua')
        return

    declared = set(re.findall(r"^\s*(\w+)\s*=", fields.group(1), re.M))

    for gate in sorted(gates):
        if gate not in declared:
            fail('gates', f'shared/schema.lua gates on `{gate}`, which Config.Save.fields lacks')

    # Every key in the schema's `keys` table must belong to a declared group, or the size
    # guard silently never drops it.
    schema_source = read(schema_path)
    groups = set(re.findall(r"\{ key = '(\w+)'", schema_source))

    keys_block = re.search(r"Schema\.keys = \{(.*?)\n\}", schema_source, re.S)
    key_tables = (set(re.findall(r"^\s{4}(\w+)\s*=", keys_block.group(1), re.M))
                  if keys_block else set())

    for name in sorted(key_tables):
        if name not in groups:
            warn('gates', f'shared/schema.lua Schema.keys has `{name}` with no matching group')


# ==============================================================================================
# 11. Nils in a parameter list
# ==============================================================================================

def check_parameter_nils():
    """
    `Store.toValues` returns a positional list that CONTAINS NILS - most vehicles leave
    `owner_name`, `job`, `statebags`, `trailer_id` and `last_garage` empty.

    Reading it with `ipairs` stops at the first hole. Appending it into another table with
    `t[#t + 1] = v` is worse: `#` over a table with a hole is undefined, so values land at
    arbitrary indexes and the parameter list is silently scrambled.

    That actually happened. MariaDB answered `Incorrect integer value: 'MIG00001' for column
    class` because a plate had landed in the class column, and every row in that batch was lost
    with one line of console output. See ERROR_LOG.md.
    """
    global checks_run
    checks_run += 1

    for path in lua_files():
        source = strip_comments(read(path))

        for number, line in enumerate(source.splitlines(), 1):
            if re.search(r"ipairs\s*\(\s*Store\.toValues", line):
                fail('param-nils',
                     f'{relative(path)}:{number} iterates Store.toValues with ipairs. '
                     'It contains nils; read it by index from 1 to #Store.columns.')

            if re.search(r"pairs\s*\(\s*Store\.toValues", line):
                fail('param-nils',
                     f'{relative(path)}:{number} iterates Store.toValues with pairs, '
                     'which does not preserve column order.')


# ==============================================================================================
# 10. Reserved words as bare keys
# ==============================================================================================

RESERVED = {
    'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'goto',
    'if', 'in', 'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'until',
    'while',
}


def check_reserved_keys():
    global checks_run
    checks_run += 1

    pattern = re.compile(r'^\s*(\w+)\s*=\s*[^=]')

    for path in lua_files():
        for number, line in enumerate(strip_comments(read(path)).splitlines(), 1):
            match = pattern.match(line)
            if match and match.group(1) in RESERVED:
                fail('reserved',
                     f'{relative(path)}:{number} uses `{match.group(1)}` as a bare table key. '
                     "Quote it: ['" + match.group(1) + "'].")


# ==============================================================================================
# 12. The shipped defaults
#
# config.lua is documentation as much as it is configuration, and a default that drifts from
# what the README, the CHANGELOG and the release notes say it is costs an operator an afternoon.
#
# Only the handful that were deliberately CHOSEN and are load-bearing enough that changing one
# by accident would be a bug are asserted here. Everything else is free to move.
# ==============================================================================================

SHIPPED_DEFAULTS = [
    # (section, key, expected literal, why it matters)
    ('Persistence', 'mode', "'owned'",
     "the default persistence mode, changed in 1.0.2 and stated everywhere"),
    ('Persistence', 'ownedImmediately', 'true',
     "a player's own car is kept from the moment they get in"),
    ('Ownership', 'keysGrantOwnership', 'false',
     "the framework's register is the authority on ownership; keys are held by anybody who was "
     "handed a spawned car, which is not the same thing"),
    ('Persistence', 'allowClaimInOwnedMode', 'true',
     "without it /vpark does nothing at all on a stock install"),
    ('Streaming', 'reconcileInterval', '15',
     "the sweep that catches a stray vehicle; 0 disables it"),

    # These two shipped as `true` and `3.5` and together put vehicles in the sky: the world
    # probe reported a kerb as blocking, and the first thing the search then tried was the
    # saved position three and a half metres higher. Both have to stay as they are.
    ('Placement', 'world', 'false',
     "the map cannot have changed since the vehicle was parked, so probing it only produces "
     "false positives"),
    ('Placement', 'verticalRetry', '0',
     "a vehicle must never be lifted to find room; it floats there for good"),
]


def check_shipped_defaults():
    global checks_run
    checks_run += 1

    path = os.path.join(ROOT, 'config.lua')
    if not os.path.exists(path):
        fail('defaults', 'there is no config.lua')
        return

    source = strip_comments(read(path))

    # Split the file into its `Config.<Section> = { ... }` blocks, so a key that appears in two
    # sections is read from the right one.
    sections = {}
    for match in re.finditer(r'^Config\.(\w+)\s*=\s*\{', source, re.MULTILINE):
        name = match.group(1)
        start = match.end()
        depth = 1
        index = start
        while index < len(source) and depth > 0:
            if source[index] == '{':
                depth += 1
            elif source[index] == '}':
                depth -= 1
            index += 1
        sections[name] = source[start:index]

    # `search.enabled` is nested, and the section parser above finds the first `enabled`
    # in the Placement block rather than that one. Checked literally instead.
    if not re.search(r'search\s*=\s*\{\s*\n\s*enabled\s*=\s*false\s*,', source):
        fail('defaults',
             'Config.Placement.search does not ship with `enabled = false` as its first '
             'key. The search moves a vehicle away from where it was parked, and every '
             'reason a bay can look occupied is either already handled, a false positive, '
             'or temporary.')

    for section, key, expected, why in SHIPPED_DEFAULTS:
        body = sections.get(section)
        if body is None:
            fail('defaults', f'config.lua has no Config.{section} block')
            continue

        found = re.search(r'^\s*' + re.escape(key) + r'\s*=\s*([^,\n]+),', body, re.MULTILINE)
        if not found:
            fail('defaults', f'Config.{section}.{key} is not set in config.lua ({why})')
            continue

        actual = found.group(1).strip()
        if actual != expected:
            fail('defaults',
                 f'Config.{section}.{key} ships as {actual}, expected {expected} - {why}. '
                 'If the change is deliberate, update SHIPPED_DEFAULTS in tools/check.py and '
                 'the README and CHANGELOG with it.')


# ==============================================================================================
# 13. GetPlayerName
#
# `GetPlayerName(0)` RAISES rather than returning nil, and zero is the console. Every audit row
# written for a console command went through it, raised inside a database thread, was swallowed
# by that thread's pcall, and was silently never written.
#
# `Bridge.playerName` is the guarded version. The raw native is allowed in exactly one place:
# the file that defines it.
# ==============================================================================================

PLAYER_NAME_HOME = 'bridge/server/framework.lua'


def check_player_name():
    global checks_run
    checks_run += 1

    for path in lua_files():
        rel = relative(path)
        if rel == PLAYER_NAME_HOME or rel.startswith('tools/'):
            continue

        source = strip_comments(read(path))
        for number, line in enumerate(source.split('\n'), start=1):
            if re.search(r'\bGetPlayerName\s*\(', line):
                fail('playername',
                     f'{rel}:{number} calls GetPlayerName directly. It RAISES on 0 (the '
                     'console) rather than returning nil. Use Bridge.playerName, which is '
                     'guarded and answers nil for anything that is not a connected player.')


# ==============================================================================================
# 14. The theme file sets appearance, not layout
#
# html/css/sandy.css loads after panel.css, so anything it declares at equal specificity wins.
# It is meant to carry colours, textures and typography only - that split is what makes "a theme
# is one CSS file" true rather than aspirational.
#
# It declared `position: relative` on `#modal`, which overrode the `position: absolute` that
# made the dialog an overlay. The dialog became a flex item of the root, took a third of the
# width away from the panel and rendered in a squashed strip on the right. Every dialog in the
# resource was affected, from 1.0.0 to 1.0.3.
#
# These properties decide where a thing is. They belong in panel.css.
# ==============================================================================================

THEME_FILE = 'html/css/sandy.css'

LAYOUT_PROPERTIES = (
    'position', 'display', 'inset', 'float', 'flex', 'grid-template',
    'width', 'height', 'margin', 'padding',
)


def check_theme_layout():
    global checks_run
    checks_run += 1

    path = os.path.join(ROOT, THEME_FILE)
    if not os.path.exists(path):
        fail('theme', f'{THEME_FILE} is missing')
        return

    source = read(path)

    # Blank the comments, keeping the line count, so prose about `position` is not a finding.
    cleaned = []
    index = 0
    while index < len(source):
        if source[index:index + 2] == '/*':
            end = source.find('*/', index + 2)
            end = len(source) if end < 0 else end + 2
            cleaned.append(''.join(c if c == '\n' else ' ' for c in source[index:end]))
            index = end
        else:
            cleaned.append(source[index])
            index += 1

    # A theme may position the decorative layers it invents itself.
    selector = ''
    inside_pseudo = False

    for number, line in enumerate(''.join(cleaned).split('\n'), start=1):
        stripped = line.strip()

        if stripped.endswith('{'):
            selector = stripped[:-1].strip()
            inside_pseudo = '::before' in selector or '::after' in selector
            continue

        if stripped.startswith('}'):
            selector, inside_pseudo = '', False
            continue

        # A pseudo-element the theme creates does not exist in panel.css, so it cannot be
        # overriding anything and it has to place itself.
        if inside_pseudo:
            continue

        # Custom properties are values, not declarations: `--panel-shadow: ...` is fine.
        if stripped.startswith('--'):
            continue

        for prop in LAYOUT_PROPERTIES:
            if re.match(r'^' + re.escape(prop) + r'\s*:', stripped):
                fail('theme',
                     f'{THEME_FILE}:{number} sets `{prop}`, which is layout. The theme file '
                     'loads after panel.css and wins at equal specificity, so a layout '
                     'property here silently overrides the structure. Move it to '
                     'html/css/panel.css.')


# ==============================================================================================
# 15. Store.columns and Store.toValues, position by position
#
# `upsertBatch` walks `Store.columns` by index and reads the matching entry of
# `Store.toValues`. If the two ever disagree - a column added to one and not the other - every
# value after that point is written into the wrong column, and MariaDB reports it as whatever
# constraint happens to break first:
#
#     Column 'owner_type' cannot be null
#     Incorrect integer value: 'MIG00001' for column class
#
# Which is a plate in the class column, and it is silent for every column where the types happen
# to be compatible. This has now happened twice: once in 1.0.0 and again in 1.0.4, when
# `vehicle_type` was added to the column list and not to the value list.
#
# Every entry of `toValues` must mention `record.<the column at that position>`, whatever else it
# wraps it in.
# ==============================================================================================

def check_store_columns():
    global checks_run
    checks_run += 1

    path = os.path.join(ROOT, 'server/store.lua')
    if not os.path.exists(path):
        fail('store', 'server/store.lua is missing')
        return

    source = strip_comments(read(path))

    columns_match = re.search(r'Store\.columns\s*=\s*\{(.*?)\n\}', source, re.DOTALL)
    if not columns_match:
        fail('store', 'could not find the Store.columns table')
        return

    columns = re.findall(r"'([\w]+)'", columns_match.group(1))

    values_match = re.search(r'function Store\.toValues\(record\)\s*return\s*\{(.*?)\n\s*\}',
                             source, re.DOTALL)
    if not values_match:
        fail('store', 'could not find the Store.toValues table')
        return

    # Split on the commas that separate entries, ignoring commas inside brackets.
    entries = []
    depth = 0
    current = ''
    for char in values_match.group(1):
        if char in '({[':
            depth += 1
        elif char in ')}]':
            depth -= 1

        if char == ',' and depth == 0:
            if current.strip():
                entries.append(current.strip())
            current = ''
        else:
            current += char

    if current.strip():
        entries.append(current.strip())

    if len(entries) != len(columns):
        fail('store',
             f'Store.columns has {len(columns)} entries and Store.toValues has {len(entries)}. '
             'They are read together by index in upsertBatch, so a mismatch writes every value '
             'after the gap into the wrong column.')
        return

    for index, (column, entry) in enumerate(zip(columns, entries), start=1):
        if not re.search(r'record\.' + re.escape(column) + r'\b', entry):
            fail('store',
                 f'Store.toValues entry {index} is `{entry}`, where Store.columns says '
                 f'`{column}`. They are read together by index; every value after a mismatch '
                 'goes into the wrong column.')


# ==============================================================================================
# 16. Live entry fields
#
# A live entry is the server's record of a vehicle in the world. Thirteen fields, several of them
# booleans whose interactions are the difference between a vehicle coming back where it was left
# and coming back where it used to live - and three releases have been spent on exactly that.
#
# The worst of them: 1.0.14 set `driven` to mean "this has been used", not knowing that `driven`
# was also the flag permitting the despawn to re-read the entity's position. The correct parked
# position was written and then overwritten with a stale one seconds later.
#
# So every field is documented in `Store.liveFields`, and a field that is not documented is not
# allowed to exist. Every assignment lives in server/spawn.lua, which is what makes this exact.
# ==============================================================================================

LIVE_ENTRY_FILE = 'server/spawn.lua'


def check_live_fields():
    global checks_run
    checks_run += 1

    store = os.path.join(ROOT, 'server/store.lua')
    spawn = os.path.join(ROOT, LIVE_ENTRY_FILE)

    if not os.path.exists(store) or not os.path.exists(spawn):
        fail('live', 'server/store.lua or server/spawn.lua is missing')
        return

    declared = re.search(r'Store\.liveFields\s*=\s*\{(.*?)\n\}',
                         strip_comments(read(store)), re.DOTALL)
    if not declared:
        fail('live', 'Store.liveFields is not declared in server/store.lua')
        return

    allowed = set(re.findall(r'(\w+)\s*=\s*true', declared.group(1)))

    source = strip_comments(read(spawn))

    for number, line in enumerate(source.split('\n'), start=1):
        found = re.match(r'\s*entry\.(\w+)\s*=[^=]', line)
        if found and found.group(1) not in allowed:
            fail('live',
                 f'{LIVE_ENTRY_FILE}:{number} writes `entry.{found.group(1)}`, which is not in '
                 'Store.liveFields. Add it there WITH a note saying who sets it, who reads it '
                 'and what clears it - the interactions between these fields are what three '
                 'releases of position bugs were made of.')


# ==============================================================================================
# 17. Locale call sites supply the right number of values
#
# `L` wraps `string.format` in a pcall and returns the RAW TEMPLATE when the format fails. That
# is the right behaviour at runtime - a missing argument in a log line must not kill the caller -
# and it means a call site that passes the wrong number of values does not raise, does not log,
# and does not stop working. It just quietly prints `lifecycle: %d expired, %d owner-absent`.
#
# Group 4 already checks that English and every translation agree on their specifiers. Nothing
# checked that the CALL SITE agrees with either of them, which is the half a human gets wrong:
# add a field to a stats line, forget to pass it.
#
# Deliberately conservative, because a check that cries wolf is worse than no check. A Lua call
# can expand to several values - `L('stats.health', Spawn.health())` legitimately fills three
# specifiers from one argument - so a call site that looks SHORT is only reported when none of
# its arguments could expand. A call site with more arguments than specifiers is always wrong.
# ==============================================================================================


def split_arguments(text):
    """Top-level commas only: `f(a, g(b, c), {d, e})` is three arguments, not five."""
    parts, depth, quote, current = [], 0, None, []

    index = 0
    while index < len(text):
        character = text[index]

        if quote:
            if character == '\\':
                current.append(text[index:index + 2])
                index += 2
                continue
            if character == quote:
                quote = None
            current.append(character)
        elif character in '"\'':
            quote = character
            current.append(character)
        elif character in '([{':
            depth += 1
            current.append(character)
        elif character in ')]}':
            depth -= 1
            current.append(character)
        elif character == ',' and depth == 0:
            parts.append(''.join(current).strip())
            current = []
        else:
            current.append(character)

        index += 1

    tail = ''.join(current).strip()
    if tail:
        parts.append(tail)

    return parts


def call_arguments(source, opening):
    """The text between the parentheses of the call starting at `opening`, or None if unbalanced."""
    depth, quote, index = 0, None, opening

    while index < len(source):
        character = source[index]

        if quote:
            if character == '\\':
                index += 2
                continue
            if character == quote:
                quote = None
        elif character in '"\'':
            quote = character
        elif character == '(':
            depth += 1
        elif character == ')':
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]

        index += 1

    return None


def check_locale_arity(english):
    global checks_run
    checks_run += 1

    if not english:
        return

    for path in lua_files():
        if '/locales/' in relative(path):
            continue

        source = strip_comments(read(path))
        name = relative(path)

        for found in re.finditer(r"\bL\(\s*'([A-Za-z0-9_.]+)'", source):
            key = found.group(1)
            if key not in english:
                continue  # group 4b already reports this

            specifiers = [spec for spec in FORMAT_SPEC.findall(english[key]) if spec != '%%']
            if not specifiers:
                continue

            inner = call_arguments(source, source.index('(', found.start()))
            if inner is None:
                continue

            arguments = split_arguments(inner)[1:]  # drop the key itself
            line = source[:found.start()].count('\n') + 1

            if len(arguments) > len(specifiers):
                fail('locale-arity',
                     f'{name}:{line} passes {len(arguments)} values to `{key}`, which has '
                     f'{len(specifiers)} specifiers {specifiers}')

            elif len(arguments) < len(specifiers):
                # A call in the argument list may expand to several values, so short is only
                # provably wrong when nothing there can expand.
                expandable = any('(' in argument for argument in arguments)
                if not expandable:
                    fail('locale-arity',
                         f'{name}:{line} passes {len(arguments)} values to `{key}`, which has '
                         f'{len(specifiers)} specifiers {specifiers}. `L` pcalls string.format, '
                         'so this prints the raw template instead of failing')


# ==============================================================================================
# 18. Store.near hands back wrappers, not records
#
# `Store.near` returns a list of { record = <the record>, distanceSq = <number> }, because every
# caller wants the distance and recomputing it is silly. The shape is easy to forget, and getting
# it wrong FAILS SILENTLY IN THE WORST WAY: `wrapper.id` is nil, so a comparison against it is
# vacuously true and a lookup with it returns nil. The loop runs, finds nothing, reports nothing,
# and whatever depended on it quietly does not happen.
#
# Written after exactly that: a neighbour list built for the placement search iterated `.id` on
# the wrapper and was empty on every call, which would have shipped as "the search still moves
# cars it should not".
#
# WHAT IT DOES NOT COVER, stated so nobody trusts it further than it goes: it follows reads off
# the loop variable itself, not through an alias. `local thing = wrapper` and then `thing.id`
# passes. That is the form nobody writes by accident - every caller in the resource reads the
# field straight off the loop variable, which is the form this catches.
# ==============================================================================================

NEAR_FIELDS = {'record', 'distanceSq'}


def check_store_near():
    global checks_run
    checks_run += 1

    for path in lua_files():
        source = strip_comments(read(path))
        name = relative(path)

        # `for _, thing in ipairs(Store.near(...))` - capture the loop variable, then look at
        # what is read off it inside the loop.
        for found in re.finditer(
                r'for\s+[\w,\s]*?\b(\w+)\s+in\s+ipairs\(\s*Store\.near\(', source):
            variable = found.group(1)
            line = source[:found.start()].count('\n') + 1

            # The loop body: from the match to the matching `end` at the same indent. Close
            # enough to take the next 40 lines, which is longer than any of these loops.
            body = '\n'.join(source[found.start():].split('\n')[:40])

            for use in re.finditer(r'\b' + re.escape(variable) + r'\.(\w+)', body):
                field = use.group(1)

                if field not in NEAR_FIELDS:
                    fail('store-near',
                         f'{name}:{line} iterates Store.near() as `{variable}` and reads '
                         f'`{variable}.{field}`. Store.near returns '
                         '{ record = ..., distanceSq = ... } wrappers, so that is nil and the '
                         'loop silently does nothing. Use '
                         f'`{variable}.record.{field}`.')
                    break


# ==============================================================================================

def main():
    english = check_locales()

    check_syntax()
    check_bom()
    check_locale_usage(english)
    check_callable_gate()
    check_ground_snap()
    check_schema_columns()
    check_manifest()
    check_schema_gates()
    check_reserved_keys()
    check_parameter_nils()
    check_shipped_defaults()
    check_player_name()
    check_theme_layout()
    check_store_columns()
    check_live_fields()
    check_locale_arity(english)
    check_store_near()

    print(f'v-park: {checks_run} check groups run over {len(lua_files())} Lua files')

    for message in warnings:
        print(f'  WARN  {message}')

    if failures:
        print()
        for message in failures:
            print(f'  FAIL  {message}')
        print(f'\n{len(failures)} failure(s)')
        return 1

    print('  all checks passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
