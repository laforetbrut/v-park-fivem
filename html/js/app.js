/*
    html/js/app.js

    The admin panel.

    -------------------------------------------------------------------------------------------
    NO FRAMEWORK, AND WHY
    -------------------------------------------------------------------------------------------

    This page renders one table of at most a hundred rows and four small dialogs. A framework
    would be a hundred kilobytes of runtime shipped to every client to save perhaps forty lines
    of DOM code, and it would be a build step in a resource that otherwise has none.

    Everything below is plain DOM against a page that is already in the HTML.

    -------------------------------------------------------------------------------------------
    NOTHING IS EVER INSERTED AS HTML
    -------------------------------------------------------------------------------------------

    Every value that reaches the page comes from a database row, and a database row on a public
    server contains whatever a player typed into a vehicle label or whatever another resource
    wrote into a plate. `innerHTML` with any of that in it is a cross-site scripting hole inside
    a browser that has NUI callbacks attached to it, which is about as bad as it sounds.

    So: `textContent` for every value, `document.createElement` for every node, and the only
    markup in this file is the static template already in index.html.

    -------------------------------------------------------------------------------------------
    THE PANEL IS A VIEW
    -------------------------------------------------------------------------------------------

    It never decides anything. Every action posts to the client, which posts to the server,
    which checks the permission again and does the work. The buttons this file hides are a
    convenience and not a boundary.
*/

'use strict';

const RESOURCE = (typeof GetParentResourceName === 'function')
    ? GetParentResourceName()
    : 'v-park';

// ----------------------------------------------------------------------------------- state ---

const state = {
    open: false,
    context: null,
    strings: {},
    data: null,
    tab: 'vehicles',

    query: {
        page: 1,
        filter: 'all',
        sort: 'recent',
        search: '',
    },

    trashPage: 1,
    refreshTimer: null,
    searchTimer: null,
    toastTimer: null,
    modalResolve: null,
};

const FILTERS = [
    ['all', 'panel.filter_all'],
    ['near', 'panel.filter_near'],
    ['live', 'panel.filter_live'],
    ['idle', 'panel.filter_idle'],
    ['wrecked', 'panel.filter_wrecked'],
    ['semi', 'panel.filter_semi'],
    ['owned', 'panel.filter_owned'],
    ['job', 'panel.filter_job'],
    ['unowned', 'panel.filter_unowned'],
    ['broken', 'panel.filter_broken'],
];

const SORTS = [
    ['recent', 'panel.sort_recent'],
    ['distance', 'panel.sort_distance'],
    ['idle', 'panel.sort_idle'],
    ['plate', 'panel.sort_plate'],
    ['model', 'panel.sort_model'],
];

// The row action buttons, in the order they appear. `gate` names the `Config.Panel.actions`
// key that switches the button off; `danger` gives it the red treatment.
const ACTIONS = [
    { id: 'teleportTo', gate: 'teleportTo', label: 'panel.act_goto' },
    { id: 'bringHere', gate: 'bringHere', label: 'panel.act_bring' },
    { id: 'mark', gate: null, label: 'panel.act_mark' },
    { id: 'repair', gate: 'repair', label: 'panel.act_repair' },
    { id: 'clean', gate: 'clean', label: 'panel.act_clean' },
    { id: 'refuel', gate: 'refuel', label: 'panel.act_refuel', prompt: 'number' },
    { id: 'unlock', gate: 'unlock', label: 'panel.act_unlock' },
    { id: 'rename', gate: 'rename', label: 'panel.act_rename', prompt: 'text' },
    { id: 'setOwner', gate: 'setOwner', label: 'panel.act_owner', prompt: 'text' },
    { id: 'toGarage', gate: 'toGarage', label: 'panel.act_garage', prompt: 'garage' },
    { id: 'impound', gate: 'impound', label: 'panel.act_impound', confirm: true },
    { id: 'delete', gate: 'delete', label: 'panel.act_delete', confirm: true, danger: true },
];

// ------------------------------------------------------------------------------- utilities ---

const $ = (id) => document.getElementById(id);

function t(key, fallback) {
    const value = state.strings[key];
    return (typeof value === 'string' && value.length) ? value : (fallback || key);
}

function post(name, body) {
    return fetch(`https://${RESOURCE}/${name}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(body || {}),
    }).catch(() => {
        /* The client always answers. A rejection here means the resource stopped underneath
           us, in which case there is nothing useful to do and nothing to report to. */
    });
}

function clear(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
}

function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
}

function toast(message, isError) {
    const node = $('toast');
    node.textContent = message || '';
    node.classList.toggle('is-error', !!isError);
    node.hidden = false;

    clearTimeout(state.toastTimer);
    state.toastTimer = setTimeout(() => { node.hidden = true; }, 3600);
}

// ---------------------------------------------------------------------------------- render ---

function fillSelect(select, entries, current) {
    clear(select);

    entries.forEach(([value, key]) => {
        const option = el('option', null, t(key));
        option.value = value;
        if (value === current) option.selected = true;
        select.appendChild(option);
    });
}

function applyStrings() {
    $('title').textContent = t('panel.title', 'V-PARK');
    $('subtitle').textContent = t('panel.subtitle', '');
    $('search').placeholder = t('panel.search', 'Search');

    $('stat-total-label').textContent = t('panel.summary_total');
    $('stat-live-label').textContent = t('panel.summary_live');
    $('stat-pending-label').textContent = t('panel.summary_pending');

    const headers = ['panel.col_vehicle', 'panel.col_owner', 'panel.col_where',
        'panel.col_state', 'panel.col_actions'];
    document.querySelectorAll('#table thead th').forEach((th, index) => {
        th.textContent = t(headers[index]);
    });

    document.querySelectorAll('.tab').forEach((tab) => {
        tab.textContent = t('panel.tab_' + tab.dataset.tab);
    });

    $('empty').textContent = t('panel.no_results');
    $('trash-empty').textContent = t('panel.trash_empty');
    $('cleanup-empty').textContent = t('panel.cleanup_empty');
    $('cleanup-note').textContent = t('panel.cleanup_note');
    $('close').title = t('panel.close') + ' (ESC)';

    fillSelect($('filter'), FILTERS, state.query.filter);
    fillSelect($('sort'), SORTS, state.query.sort);
}

/*
    The condition meter: body health on the left bar, engine on the right.

    Two bars rather than one averaged number, because a car with a perfect body and a dead
    engine is a completely different problem from one with the reverse, and an average hides
    exactly that.
*/
function meter(row) {
    const wrap = el('div', 'meter');

    [['bodyHealth', row.bodyHealth], ['engineHealth', row.engineHealth]].forEach(([, value]) => {
        const bar = el('div', 'meter-bar');
        const fill = el('div', 'meter-fill');

        const ratio = Math.max(0, Math.min(1, (Number(value) || 0) / 1000));
        fill.style.right = `${(1 - ratio) * 100}%`;

        if (ratio <= 0.02) fill.classList.add('is-dead');
        else if (ratio < 0.4) fill.classList.add('is-low');

        bar.appendChild(fill);
        wrap.appendChild(bar);
    });

    return wrap;
}

function chip(text, className) {
    return el('span', 'chip ' + className, text);
}

function vehicleCell(row) {
    const cell = el('td');

    const model = el('span', 'v-model', row.model || '?');
    if (row.label) model.appendChild(el('span', 'v-label', row.label));
    cell.appendChild(model);

    const parts = [];
    if (row.plate) parts.push(row.plate);
    if (row.className) parts.push(row.className);
    parts.push(row.id);

    cell.appendChild(el('span', 'v-sub', parts.join('  ·  ')));
    return cell;
}

function ownerCell(row) {
    const cell = el('td');
    cell.appendChild(el('span', 'v-model', row.owner || '—'));

    const sub = [row.ownerType];
    if (row.job) sub.push(row.job);
    cell.appendChild(el('span', 'v-sub', sub.join('  ·  ')));

    return cell;
}

function whereCell(row) {
    const cell = el('td');

    const coords = `${Math.round(row.x)}, ${Math.round(row.y)}`;
    cell.appendChild(el('span', 'v-model', coords));

    const sub = [];
    if (typeof row.distance === 'number') sub.push(`${row.distance} m`);
    if (row.interior) sub.push('interior');
    if (row.bucket) sub.push(`bucket ${row.bucket}`);
    if (row.lastGarage) sub.push(row.lastGarage);

    cell.appendChild(el('span', 'v-sub', sub.join('  ·  ')));
    return cell;
}

function stateCell(row) {
    const cell = el('td');
    const chips = el('div');

    chips.appendChild(row.live
        ? chip(t('panel.in_world'), 'chip-live')
        : chip(t('panel.stored'), 'chip-stored'));

    if (row.wrecked) chips.appendChild(chip(t('panel.wrecked'), 'chip-wrecked'));
    if (row.idleDue) chips.appendChild(chip(t('panel.idle_due'), 'chip-due'));
    if (row.invalidModel) chips.appendChild(chip('MODEL', 'chip-broken'));
    if (row.graceText) chips.appendChild(chip(`${t('panel.grace')} ${row.graceText}`, 'chip-grace'));

    cell.appendChild(chips);
    cell.appendChild(meter(row));

    const idle = row.idleText
        ? `${t('panel.idle')} ${row.idleText}`
        : t('panel.never_used');
    cell.appendChild(el('span', 'v-sub', idle));

    return cell;
}

// How many actions sit on the row itself. The rest go behind the overflow button.
const INLINE_ACTIONS = 3;

/*
    Close any open overflow menu.

    A single open menu at a time, tracked on the document rather than per row, because the
    alternative is a click handler per row that has to know about every other row.
*/
function closeMenus() {
    document.querySelectorAll('.act-menu').forEach((menu) => menu.remove());
    document.querySelectorAll('tr.has-menu').forEach((tr) => tr.classList.remove('has-menu'));
}

document.addEventListener('click', (event) => {
    if (!event.target.closest('.row-actions')) closeMenus();
});

function actionsCell(row) {
    const cell = el('td', 'col-actions');
    const wrap = el('div', 'row-actions');

    const allowed = (state.context && state.context.actions) || {};

    const available = ACTIONS.filter((action) => {
        if (action.gate && allowed[action.gate] === false) return false;
        return true;
    });

    const makeButton = (action) => {
        const button = el('button', 'btn act' + (action.danger ? ' btn-danger' : ''), t(action.label));
        button.type = 'button';
        button.addEventListener('click', (event) => {
            event.stopPropagation();
            closeMenus();
            runAction(action, row);
        });
        return button;
    };

    available.slice(0, INLINE_ACTIONS).forEach((action) => wrap.appendChild(makeButton(action)));

    const overflow = available.slice(INLINE_ACTIONS);

    if (overflow.length) {
        const more = el('button', 'btn act act-more', '⋯');
        more.type = 'button';
        more.title = t('panel.col_actions');

        more.addEventListener('click', (event) => {
            event.stopPropagation();

            // Toggling: a second click on the same button closes it rather than rebuilding
            // an identical menu underneath the first.
            const alreadyOpen = wrap.querySelector('.act-menu');
            closeMenus();
            if (alreadyOpen) return;

            const menu = el('div', 'act-menu');
            overflow.forEach((action) => menu.appendChild(makeButton(action)));
            wrap.appendChild(menu);

            const tr = cell.closest('tr');
            if (tr) tr.classList.add('has-menu');
        });

        wrap.appendChild(more);
    }

    cell.appendChild(wrap);
    return cell;
}

function renderRows() {
    const body = $('rows');

    // Any open overflow menu belongs to a row that is about to be destroyed. Closing it first
    // keeps the document-level tracking honest.
    closeMenus();
    clear(body);

    const data = state.data;
    const rows = (data && data.rows) || [];

    $('empty').hidden = rows.length > 0;

    rows.forEach((row) => {
        const tr = el('tr');
        tr.appendChild(vehicleCell(row));
        tr.appendChild(ownerCell(row));
        tr.appendChild(whereCell(row));
        tr.appendChild(stateCell(row));
        tr.appendChild(actionsCell(row));
        body.appendChild(tr);
    });

    if (data) {
        $('page-label').textContent = `${t('panel.page')} ${data.page} ${t('panel.of')} ${data.pages}`;
        $('total-label').textContent = `${data.total} ${t('panel.total')}`;
        $('prev').disabled = data.page <= 1;
        $('next').disabled = data.page >= data.pages;

        if (data.summary) {
            $('stat-total').textContent = data.summary.total;
            $('stat-live').textContent = data.summary.live;
            $('stat-pending').textContent = data.summary.dirty;
        }
    }
}

function renderTrash(data) {
    const body = $('trash-rows');
    clear(body);

    const rows = (data && data.rows) || [];
    $('trash-empty').hidden = rows.length > 0;

    rows.forEach((row) => {
        const tr = el('tr');

        const vehicle = el('td');
        vehicle.appendChild(el('span', 'v-model', row.model || '?'));
        vehicle.appendChild(el('span', 'v-sub', [row.plate, row.id].filter(Boolean).join('  ·  ')));
        tr.appendChild(vehicle);

        tr.appendChild(el('td', null, row.owner || '—'));
        tr.appendChild(el('td', null, row.deletedAgo || '?'));
        tr.appendChild(el('td', null, [row.reason, row.deletedBy].filter(Boolean).join(' / ')));

        const actions = el('td', 'col-actions');
        const button = el('button', 'btn act btn-primary', t('panel.trash_restore'));
        button.type = 'button';
        button.addEventListener('click', () => {
            post('action', { action: 'restore', id: row.id });
        });
        actions.appendChild(button);
        tr.appendChild(actions);

        body.appendChild(tr);
    });

    if (data) {
        $('trash-page-label').textContent = `${t('panel.page')} ${data.page} ${t('panel.of')} ${data.pages}`;
        $('trash-prev').disabled = data.page <= 1;
        $('trash-next').disabled = data.page >= data.pages;
    }
}

function renderCleanup(report) {
    const body = $('cleanup-rows');
    clear(body);

    const rows = report || [];
    $('cleanup-empty').hidden = rows.length > 0;

    rows.forEach((row) => {
        const tr = el('tr');

        const vehicle = el('td');
        vehicle.appendChild(el('span', 'v-model', row.model || '?'));
        vehicle.appendChild(el('span', 'v-sub', [row.plate, row.id].filter(Boolean).join('  ·  ')));
        tr.appendChild(vehicle);

        tr.appendChild(el('td', null, row.owner || '—'));
        tr.appendChild(el('td', null, row.idle || '?'));
        tr.appendChild(el('td', null, row.destination || '—'));

        body.appendChild(tr);
    });
}

// ---------------------------------------------------------------------------------- actions ---

/*
    One modal, reconfigured per use, returning a promise.

    Three separate dialogs would be three places to forget to release the keyboard - and the
    keyboard is what the game takes back when this page closes, so forgetting it once means a
    player who cannot move.
*/
function ask(options) {
    return new Promise((resolve) => {
        state.modalResolve = resolve;

        $('modal-title').textContent = options.title || '';
        $('modal-body').textContent = options.body || '';

        const input = $('modal-input');
        const select = $('modal-select');

        input.hidden = true;
        select.hidden = true;
        input.value = '';

        if (options.kind === 'text' || options.kind === 'number') {
            input.hidden = false;
            input.type = options.kind === 'number' ? 'number' : 'text';
            if (options.value !== undefined) input.value = options.value;
        } else if (options.kind === 'garage') {
            select.hidden = false;
            clear(select);

            const garages = (state.context && state.context.garages) || [];
            if (garages.length === 0) {
                const option = el('option', null, '—');
                option.value = '';
                select.appendChild(option);
            }
            garages.forEach((garage) => {
                const option = el('option', null, garage.label || garage.id);
                option.value = garage.id;
                select.appendChild(option);
            });
        }

        $('modal-confirm').className = 'btn ' + (options.danger ? 'btn-danger' : 'btn-primary');
        $('modal-confirm').textContent = t('panel.confirm');
        $('modal-cancel').textContent = t('panel.cancel');

        $('modal').hidden = false;

        if (!input.hidden) setTimeout(() => input.focus(), 30);
    });
}

function closeModal(value) {
    $('modal').hidden = true;

    const resolve = state.modalResolve;
    state.modalResolve = null;
    if (resolve) resolve(value);
}

async function runAction(action, row) {
    // Purely local: a waypoint costs no server round trip and should not wait for one.
    if (action.id === 'mark') {
        post('mark', { x: row.x, y: row.y, z: row.z });
        toast(t('panel.act_mark'));
        return;
    }

    let value;

    if (action.prompt === 'garage') {
        value = await ask({
            kind: 'garage',
            title: t('panel.act_garage'),
            body: t('panel.choose_garage'),
        });
        if (value === null) return;
        value = $('modal-select').value;

    } else if (action.prompt === 'text') {
        const body = action.id === 'rename' ? t('panel.rename_prompt') : t('panel.owner_prompt');
        value = await ask({
            kind: 'text',
            title: t(action.label),
            body,
            value: action.id === 'rename' ? (row.label || '') : '',
        });
        if (value === null) return;

    } else if (action.prompt === 'number') {
        value = await ask({
            kind: 'number',
            title: t(action.label),
            body: t('panel.refuel_prompt'),
            value: 100,
        });
        if (value === null) return;

    } else if (action.confirm) {
        const confirmed = await ask({
            title: t(action.label),
            body: action.id === 'delete'
                ? t('panel.confirm_delete')
                : `${t(action.label)}: ${row.model || row.id}`,
            danger: !!action.danger,
        });
        if (confirmed === null) return;
    }

    post('action', { action: action.id, id: row.id, value });
}

// ------------------------------------------------------------------------------------ query ---

function refresh() {
    post('query', state.query);
}

function setTab(name) {
    state.tab = name;

    document.querySelectorAll('.tab').forEach((tab) => {
        tab.classList.toggle('is-active', tab.dataset.tab === name);
    });

    document.querySelectorAll('.view').forEach((view) => {
        view.classList.toggle('is-active', view.dataset.view === name);
    });

    if (name === 'trash') {
        post('trash', { page: state.trashPage });
    } else if (name === 'cleanup') {
        post('cleanupPreview', {});
    }
}

// ------------------------------------------------------------------------------------ wiring ---

$('close').addEventListener('click', () => post('close', {}));

$('refresh').addEventListener('click', refresh);

$('prev').addEventListener('click', () => {
    state.query.page = Math.max(1, state.query.page - 1);
    refresh();
});

$('next').addEventListener('click', () => {
    state.query.page += 1;
    refresh();
});

$('trash-prev').addEventListener('click', () => {
    state.trashPage = Math.max(1, state.trashPage - 1);
    post('trash', { page: state.trashPage });
});

$('trash-next').addEventListener('click', () => {
    state.trashPage += 1;
    post('trash', { page: state.trashPage });
});

$('filter').addEventListener('change', (event) => {
    state.query.filter = event.target.value;
    state.query.page = 1;
    refresh();
});

$('sort').addEventListener('change', (event) => {
    state.query.sort = event.target.value;
    state.query.page = 1;
    refresh();
});

// Debounced, because every keystroke would otherwise be a full server-side filter and sort of
// the whole store.
$('search').addEventListener('input', (event) => {
    state.query.search = event.target.value;
    state.query.page = 1;

    clearTimeout(state.searchTimer);
    state.searchTimer = setTimeout(refresh, 220);
});

document.querySelectorAll('.tab').forEach((tab) => {
    tab.addEventListener('click', () => setTab(tab.dataset.tab));
});

$('modal-cancel').addEventListener('click', () => closeModal(null));

$('modal-confirm').addEventListener('click', () => {
    const input = $('modal-input');
    closeModal(input.hidden ? true : input.value);
});

$('modal-input').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
        event.preventDefault();
        closeModal($('modal-input').value);
    }
});

/*
    ESCAPE.

    Handled here as well as in Lua. The Lua handler is the one that works when this page has
    stopped responding; this one is the one that works instantly and closes a modal without
    closing the whole panel.
*/
document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;

    if (!$('modal').hidden) {
        closeModal(null);
        return;
    }

    if (state.open) post('close', {});
});

// --------------------------------------------------------------------------- messages in ---

window.addEventListener('message', (event) => {
    const message = event.data;
    if (!message || typeof message !== 'object') return;

    switch (message.action) {
        case 'open': {
            state.open = true;
            state.context = message.context || {};
            state.strings = message.locale || {};
            state.query = { page: 1, filter: 'all', sort: 'recent', search: '' };
            state.trashPage = 1;

            applyStrings();
            setTab('vehicles');

            state.data = message.data || null;
            renderRows();

            $('root').hidden = false;

            // Periodic refresh, so a second admin's changes appear without anybody pressing
            // anything. Cleared on close, or it keeps querying a server nobody is looking at.
            clearInterval(state.refreshTimer);
            const seconds = Number(state.context.refreshSeconds) || 0;
            if (seconds > 0) {
                state.refreshTimer = setInterval(() => {
                    if (state.open && state.tab === 'vehicles') refresh();
                }, seconds * 1000);
            }
            break;
        }

        case 'close': {
            state.open = false;
            $('root').hidden = true;
            $('modal').hidden = true;
            clearInterval(state.refreshTimer);
            clearTimeout(state.searchTimer);
            state.modalResolve = null;
            break;
        }

        case 'data': {
            state.data = message.data || null;
            if (state.data) {
                state.query.page = state.data.page;
                state.query.filter = state.data.filter;
                state.query.sort = state.data.sort;
            }
            renderRows();
            break;
        }

        case 'result': {
            toast(message.message, !message.ok);
            break;
        }

        case 'trash': {
            renderTrash(message.data);
            break;
        }

        case 'cleanup': {
            renderCleanup(message.data);
            break;
        }

        default:
            break;
    }
});
