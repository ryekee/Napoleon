'use strict';

// Only sample DOM content is searched. No desktop access, global hotkeys or storage.
const demo = document.querySelector('.demo');
const grid = demo.querySelector('.window-grid');
const cards = [...grid.querySelectorAll('.window-card')];
const search = demo.querySelector('input');
const modes = [...demo.querySelectorAll('[data-mode]')];
const previous = demo.querySelector('.previous-window');
const next = demo.querySelector('.next-window');
const within = demo.querySelector('.within-app');
const status = demo.querySelector('#demo-status');
const strings = JSON.parse(document.querySelector('#demo-copy').textContent);
const normalize = text => text.normalize('NFKC').toLocaleLowerCase().replace(/\s+/g, '');
const samples = cards.map(card => ({
  card,
  app: card.dataset.app,
  title: card.dataset.title,
  searchable: normalize(`${card.getAttribute('aria-label')} ${card.dataset.aliases}`),
}));
let mode = 'windows';
let groups = [];
let selected = 0;
let stackPositions = new Map();

function render(announce = true) {
  const query = normalize(search.value.trim());
  const matches = samples.filter(sample => sample.searchable.includes(query));
  groups = [];
  for (const sample of matches) {
    const group = mode === 'apps' && groups.find(items => items[0].app === sample.app);
    if (group) group.push(sample);
    else groups.push([sample]);
  }
  selected = Math.min(selected, Math.max(0, groups.length - 1));
  for (const card of cards) {
    card.hidden = true;
    card.tabIndex = -1;
    card.setAttribute('aria-selected', 'false');
    card.classList.remove('grouped');
    card.querySelector('.stack-count').hidden = true;
  }
  groups.forEach((group, index) => {
    const position = (stackPositions.get(group[0].app) || 0) % group.length;
    const sample = group[position];
    const card = sample.card;
    card.hidden = false;
    // Keep reading order aligned with the visible app groups after cycling a stack.
    grid.append(card);
    card.setAttribute('aria-selected', String(index === selected));
    card.tabIndex = index === selected ? 0 : -1;
    card.classList.toggle('grouped', group.length > 1);
    const count = card.querySelector('.stack-count');
    count.hidden = group.length < 2;
    count.textContent = group.length;
    const countLabel = group.length > 1 ? ` · ${strings.count.replace('{count}', group.length)}` : '';
    card.setAttribute('aria-label', `${card.querySelector('.window-label strong').textContent} — ${sample.title}${countLabel}`);
  });
  grid.hidden = groups.length === 0;
  demo.querySelector('.demo-empty').hidden = groups.length !== 0;
  previous.disabled = next.disabled = groups.length < 2;
  within.hidden = mode !== 'apps';
  within.disabled = !groups[selected] || groups[selected].length < 2;
  modes.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.mode === mode)));
  if (announce) {
    const current = groups[selected];
    status.textContent = current ? strings.selected.replace('{title}', current[(stackPositions.get(current[0].app) || 0) % current.length].title) : strings.empty;
  }
}

function step(delta, focus = false) {
  if (!groups.length) return;
  selected = (selected + delta + groups.length) % groups.length;
  render();
  if (focus) grid.querySelector('[aria-selected="true"]').focus({ preventScroll: true });
}

search.addEventListener('input', () => {
  selected = 0;
  stackPositions.clear();
  render();
});
search.addEventListener('keydown', event => {
  if (event.isComposing) return;
  if (event.key === 'Escape') {
    search.value = '';
    selected = 0;
    stackPositions.clear();
    render();
  } else if (event.key === 'ArrowDown' && groups.length) {
    event.preventDefault();
    grid.querySelector('[aria-selected="true"]').focus({ preventScroll: true });
  }
});
modes.forEach(button => button.addEventListener('click', () => {
  mode = button.dataset.mode;
  selected = 0;
  stackPositions.clear();
  render();
}));
previous.addEventListener('click', () => step(-1));
next.addEventListener('click', () => step(1));
within.addEventListener('click', () => {
  const group = groups[selected];
  if (!group || group.length < 2) return;
  stackPositions.set(group[0].app, ((stackPositions.get(group[0].app) || 0) + 1) % group.length);
  render();
});
grid.addEventListener('click', event => {
  const card = event.target.closest('.window-card');
  const index = groups.findIndex(group => group.some(sample => sample.card === card));
  if (index < 0) return;
  selected = index;
  render();
});
grid.addEventListener('keydown', event => {
  if (event.altKey || event.metaKey || event.ctrlKey || event.isComposing) return;
  const columns = getComputedStyle(grid).gridTemplateColumns.split(' ').length;
  const deltas = { ArrowRight: 1, ArrowLeft: -1, ArrowDown: columns, ArrowUp: -columns };
  if (event.key in deltas) {
    event.preventDefault();
    step(deltas[event.key], true);
  } else if (event.key === 'Home' || event.key === 'End') {
    event.preventDefault();
    selected = event.key === 'Home' ? 0 : groups.length - 1;
    step(0, true);
  } else if (event.key === 'Escape') {
    search.focus();
  }
});
demo.querySelectorAll('[data-enhance]').forEach(element => { element.hidden = false; });
render(false);
