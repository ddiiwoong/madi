import { renderMarkdown, extractOutline, escapeHtml } from './markdown.js';
import {
  createQueryDebouncer,
  findMatches,
  normalizeQuery,
  segmentByMatches,
  shouldSearch,
} from './search.js';
import {
  clearPreviewHighlight,
  highlightPreview,
  scrollToMatch,
  supportsHighlightApi,
} from './highlight.js';

const STORAGE_KEY = 'md-editor:document';
const STORAGE_VIEW = 'md-editor:view';

const el = {
  root: document.body,
  search: document.getElementById('search-input'),
  searchField: document.getElementById('search-field'),
  searchToggle: document.getElementById('search-toggle'),
  matchCount: document.getElementById('match-count'),
  source: document.getElementById('source'),
  sourceHighlight: document.getElementById('source-highlight'),
  preview: document.getElementById('preview'),
  outline: document.getElementById('outline'),
  outlineToggle: document.getElementById('outline-toggle'),
  viewToggle: document.getElementById('view-toggle'),
  openBtn: document.getElementById('open-file'),
  saveBtn: document.getElementById('save-file'),
  fileInput: document.getElementById('file-input'),
  docName: document.getElementById('doc-name'),
  status: document.getElementById('status'),
};

const state = {
  query: '',
  appliedQuery: '',
  matchIndex: 0,
  matchTotal: 0,
  fileHandle: null,
  fileName: 'untitled.md',
  dirty: false,
  view: localStorage.getItem(STORAGE_VIEW) || 'split',
};

/* ---------------------------------------------------------------- rendering */

function renderPreview() {
  el.preview.innerHTML = renderMarkdown(el.source.value);
}

function renderOutline() {
  const outline = extractOutline(el.source.value);
  if (outline.length === 0) {
    el.outline.innerHTML = '<p class="outline-empty">제목이 없습니다</p>';
    return;
  }
  el.outline.innerHTML = outline
    .map((h) => `<button type="button" class="outline-item" data-level="${h.level}" data-line="${h.line}">${escapeHtml(h.text)}</button>`)
    .join('');
}

/** Source-pane highlight layer: wraps each hit in <mark class="source-search-mark">. */
function renderSourceHighlight() {
  const text = el.source.value;
  const query = state.appliedQuery;
  if (!query) {
    el.sourceHighlight.textContent = text;
    return;
  }
  el.sourceHighlight.innerHTML = segmentByMatches(text, query)
    .map((seg) => (seg.match ? `<mark class="source-search-mark">${escapeHtml(seg.text)}</mark>` : escapeHtml(seg.text)))
    .join('');
}

function applySearch() {
  renderSourceHighlight();
  const previewCount = highlightPreview(el.preview, state.appliedQuery);
  const query = state.appliedQuery;

  if (!query) {
    state.matchTotal = 0;
    state.matchIndex = 0;
    el.matchCount.textContent = '';
    el.matchCount.hidden = true;
    return;
  }

  const sourceText = el.source.value;
  if (!shouldSearch(sourceText.length, query)) {
    el.matchCount.hidden = false;
    el.matchCount.textContent = '질의가 너무 짧습니다';
    return;
  }

  const sourceTotal = findMatches(sourceText, query).length;
  state.matchTotal = previewCount >= 0 ? previewCount : sourceTotal;
  state.matchIndex = Math.min(state.matchIndex, Math.max(0, state.matchTotal - 1));
  el.matchCount.hidden = false;

  if (state.matchTotal > 0) {
    el.matchCount.textContent = `${state.matchIndex + 1} / ${state.matchTotal}`;
  } else if (sourceTotal > 0) {
    // The preview deliberately skips code, so a query that only occurs inside
    // code highlights in the source and nowhere else. Say that, rather than
    // claiming there is no match while the source shows one.
    el.matchCount.textContent = `코드 안에서만 일치 (${sourceTotal})`;
  } else {
    el.matchCount.textContent = '일치 없음';
  }
}

const debouncer = createQueryDebouncer(
  (query) => {
    state.appliedQuery = query;
    applySearch();
  },
  () => el.source.value.length,
);

/* -------------------------------------------------------------------- state */

function markDirty(dirty) {
  state.dirty = dirty;
  el.docName.textContent = state.fileName + (dirty ? ' •' : '');
}

function setStatus(message) {
  el.status.textContent = message;
  if (!message) return;
  clearTimeout(setStatus.timer);
  setStatus.timer = setTimeout(() => {
    el.status.textContent = '';
  }, 4000);
}

function onSourceChanged({ persist = true } = {}) {
  renderPreview();
  renderOutline();
  renderSourceHighlight();
  applySearch();
  markDirty(true);
  if (persist) {
    clearTimeout(onSourceChanged.timer);
    onSourceChanged.timer = setTimeout(() => {
      localStorage.setItem(STORAGE_KEY, el.source.value);
    }, 400);
  }
}

function setView(view) {
  state.view = view;
  el.root.dataset.view = view;
  localStorage.setItem(STORAGE_VIEW, view);
  el.viewToggle.textContent = { split: '분할', source: '소스', preview: '미리보기' }[view];
}

/* ----------------------------------------------------------------- file i/o */

const hasFsAccess = typeof window.showOpenFilePicker === 'function';

async function openFile() {
  if (hasFsAccess) {
    try {
      const [handle] = await window.showOpenFilePicker({
        types: [{ description: 'Markdown', accept: { 'text/markdown': ['.md', '.markdown', '.mdown', '.mkd'] } }],
      });
      const file = await handle.getFile();
      el.source.value = await file.text();
      state.fileHandle = handle;
      state.fileName = file.name;
      onSourceChanged();
      markDirty(false);
      setStatus(`열었습니다: ${file.name}`);
    } catch (error) {
      if (error.name !== 'AbortError') setStatus(`열기 실패: ${error.message}`);
    }
    return;
  }
  el.fileInput.click();
}

async function saveFile() {
  if (hasFsAccess) {
    try {
      let handle = state.fileHandle;
      if (!handle) {
        handle = await window.showSaveFilePicker({
          suggestedName: state.fileName,
          types: [{ description: 'Markdown', accept: { 'text/markdown': ['.md'] } }],
        });
        state.fileHandle = handle;
        state.fileName = handle.name;
      }
      const writable = await handle.createWritable();
      await writable.write(el.source.value);
      await writable.close();
      markDirty(false);
      setStatus(`저장했습니다: ${state.fileName}`);
    } catch (error) {
      if (error.name !== 'AbortError') setStatus(`저장 실패: ${error.message}`);
    }
    return;
  }

  const blob = new Blob([el.source.value], { type: 'text/markdown;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = state.fileName;
  link.click();
  URL.revokeObjectURL(url);
  markDirty(false);
  setStatus(`내려받았습니다: ${state.fileName}`);
}

/* ------------------------------------------------------------------ wiring */

el.source.addEventListener('input', () => onSourceChanged());
el.source.addEventListener('scroll', () => {
  el.sourceHighlight.scrollTop = el.source.scrollTop;
  el.sourceHighlight.scrollLeft = el.source.scrollLeft;
});

el.search.addEventListener('input', () => {
  state.query = el.search.value;
  state.matchIndex = 0;
  debouncer.set(state.query);
});

/* Mark's `closeSearchIfEmpty`: `()=>{ z.trim() || Q(!1) }` */
el.search.addEventListener('blur', () => {
  if (!normalizeQuery(el.search.value)) closeSearch();
});

/*
 * Mark's `handleSearchKeyDown` does exactly one thing — Cmd/Ctrl+A selects the
 * whole field. Enter / Shift+Enter navigation below is OUR addition: Mark has
 * no match navigation at all (see README).
 */
el.search.addEventListener('keydown', (event) => {
  const meta = event.metaKey || event.ctrlKey;
  if (meta && !event.altKey && event.key.toLowerCase() === 'a') {
    event.preventDefault();
    el.search.setSelectionRange(0, el.search.value.length);
    return;
  }
  if (event.key === 'Escape') {
    event.preventDefault();
    el.search.value = '';
    state.query = '';
    debouncer.flush('');
    closeSearch();
    return;
  }
  if (event.key === 'Enter') {
    event.preventDefault();
    debouncer.flush(el.search.value);
    if (state.matchTotal === 0) return;
    const step = event.shiftKey ? -1 : 1;
    state.matchIndex = (state.matchIndex + step + state.matchTotal) % state.matchTotal;
    scrollToMatch(el.preview, state.appliedQuery, state.matchIndex);
    el.matchCount.textContent = `${state.matchIndex + 1} / ${state.matchTotal}`;
  }
});

function openSearch() {
  el.searchField.classList.add('is-open');
  el.search.focus();
  el.search.select();
}

function closeSearch() {
  if (normalizeQuery(el.search.value)) return;
  el.searchField.classList.remove('is-open');
  clearPreviewHighlight();
  el.matchCount.hidden = true;
}

el.searchToggle.addEventListener('click', openSearch);
el.outlineToggle.addEventListener('click', () => {
  el.root.classList.toggle('outline-open');
});
el.viewToggle.addEventListener('click', () => {
  const order = ['split', 'source', 'preview'];
  setView(order[(order.indexOf(state.view) + 1) % order.length]);
});
el.openBtn.addEventListener('click', () => void openFile());
el.saveBtn.addEventListener('click', () => void saveFile());

el.fileInput.addEventListener('change', async () => {
  const file = el.fileInput.files?.[0];
  if (!file) return;
  el.source.value = await file.text();
  state.fileName = file.name;
  state.fileHandle = null;
  onSourceChanged();
  markDirty(false);
  setStatus(`열었습니다: ${file.name}`);
  el.fileInput.value = '';
});

el.outline.addEventListener('click', (event) => {
  const item = event.target.closest('.outline-item');
  if (!item) return;
  const line = Number(item.dataset.line);
  const lines = el.source.value.split('\n');
  const offset = lines.slice(0, line - 1).join('\n').length + 1;
  el.source.focus();
  el.source.setSelectionRange(offset, offset);
  const ratio = (line - 1) / Math.max(1, lines.length);
  el.source.scrollTop = ratio * el.source.scrollHeight;
  el.preview.scrollTop = ratio * el.preview.scrollHeight;
});

/* Mark's global shortcut handler: Cmd+F opens search, Cmd+S saves, Cmd+E toggles source. */
window.addEventListener(
  'keydown',
  (event) => {
    if (!event.metaKey && !event.ctrlKey) return;
    const key = event.key.toLowerCase();
    if (key === 'f' && !event.shiftKey) {
      event.preventDefault();
      openSearch();
      return;
    }
    if (key === 's') {
      event.preventDefault();
      void saveFile();
      return;
    }
    if (key === 'o') {
      event.preventDefault();
      void openFile();
      return;
    }
    if (key === 'e') {
      event.preventDefault();
      el.viewToggle.click();
    }
  },
  { capture: true },
);

window.addEventListener('beforeunload', (event) => {
  localStorage.setItem(STORAGE_KEY, el.source.value);
  if (state.dirty && state.fileHandle) {
    event.preventDefault();
    event.returnValue = '';
  }
});

/* ------------------------------------------------------------------- start */

const saved = localStorage.getItem(STORAGE_KEY);
if (saved !== null) el.source.value = saved;

setView(state.view);
renderPreview();
renderOutline();
renderSourceHighlight();
markDirty(false);

if (!supportsHighlightApi()) {
  setStatus('이 브라우저는 CSS Highlight API가 없어 미리보기 강조가 꺼집니다 (소스 강조는 동작).');
}
