/**
 * A small CommonMark-ish renderer with no dependencies.
 *
 * Security: every character of the input is HTML-escaped before any markup is
 * emitted, and raw HTML in the source is NOT passed through. That makes the
 * output safe by construction, so no sanitiser is needed. Link and image URLs
 * are additionally restricted to http/https/mailto/relative targets, so
 * `javascript:` and `data:` cannot reach an href.
 *
 * Supported: fenced code, ATX headings, thematic breaks, blockquotes, ordered
 * and unordered lists (nested by indentation), tables, paragraphs; inline code,
 * bold, italic, strikethrough, links, images, autolinks, hard line breaks.
 */

const BLOCK_PLACEHOLDER = '\u0000CODE';

export function escapeHtml(text) {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function safeUrl(raw) {
  const url = raw.trim();
  if (/^(https?:|mailto:)/i.test(url)) return url;
  if (/^[a-z][a-z0-9+.-]*:/i.test(url)) return '';
  return url;
}

export function slugify(text) {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s-]/gu, '')
    .trim()
    .replace(/\s+/g, '-');
}

function renderInline(text) {
  const codeSpans = [];
  let out = text.replace(/`([^`]+)`/g, (_, code) => {
    codeSpans.push(code);
    return `${BLOCK_PLACEHOLDER}${codeSpans.length - 1}\u0000`;
  });

  out = escapeHtml(out);

  out = out.replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;([^&]*)&quot;)?\)/g, (m, alt, src, title) => {
    const url = safeUrl(src);
    if (!url) return m;
    const titleAttr = title ? ` title="${title}"` : '';
    return `<img src="${url}" alt="${alt}"${titleAttr} loading="lazy">`;
  });

  out = out.replace(/\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;([^&]*)&quot;)?\)/g, (m, label, href, title) => {
    const url = safeUrl(href);
    if (!url) return m;
    const titleAttr = title ? ` title="${title}"` : '';
    const external = /^https?:/i.test(url) ? ' target="_blank" rel="noreferrer noopener"' : '';
    return `<a href="${url}"${titleAttr}${external}>${label}</a>`;
  });

  out = out.replace(/&lt;(https?:\/\/[^\s&]+)&gt;/g, '<a href="$1" target="_blank" rel="noreferrer noopener">$1</a>');
  out = out.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  out = out.replace(/__([^_]+)__/g, '<strong>$1</strong>');
  out = out.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
  out = out.replace(/(^|[^\w_])_([^_\n]+)_/g, '$1<em>$2</em>');
  out = out.replace(/~~([^~]+)~~/g, '<del>$1</del>');
  out = out.replace(/ {2}$/gm, '<br>');

  return out.replace(new RegExp(`${BLOCK_PLACEHOLDER}(\\d+)\\u0000`, 'g'), (_, i) => `<code>${escapeHtml(codeSpans[Number(i)])}</code>`);
}

function renderTable(rows) {
  const cells = (line) => line.replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
  const head = cells(rows[0]);
  const aligns = cells(rows[1]).map((spec) => {
    if (/^:-+:$/.test(spec)) return ' style="text-align:center"';
    if (/^-+:$/.test(spec)) return ' style="text-align:right"';
    return '';
  });
  const body = rows.slice(2).map((row) => {
    const tds = cells(row).map((cell, i) => `<td${aligns[i] || ''}>${renderInline(cell)}</td>`).join('');
    return `<tr>${tds}</tr>`;
  }).join('');
  const ths = head.map((cell, i) => `<th${aligns[i] || ''}>${renderInline(cell)}</th>`).join('');
  return `<table><thead><tr>${ths}</tr></thead><tbody>${body}</tbody></table>`;
}

function isTableDelimiter(line) {
  return /^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/.test(line) && line.includes('-');
}

/** @returns {string} HTML */
export function renderMarkdown(source) {
  const lines = String(source ?? '').replace(/\r\n?/g, '\n').split('\n');
  const html = [];
  const listStack = [];

  const closeLists = (toDepth = 0) => {
    while (listStack.length > toDepth) html.push(`</${listStack.pop().tag}>`);
  };

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];

    const fence = line.match(/^\s*(```|~~~)\s*([\w+-]*)\s*$/);
    if (fence) {
      closeLists();
      const marker = fence[1];
      const lang = fence[2];
      const buffer = [];
      i += 1;
      while (i < lines.length && !new RegExp(`^\\s*${marker}\\s*$`).test(lines[i])) {
        buffer.push(lines[i]);
        i += 1;
      }
      const langClass = lang ? ` class="language-${escapeHtml(lang)}"` : '';
      html.push(`<pre><code${langClass}>${escapeHtml(buffer.join('\n'))}</code></pre>`);
      continue;
    }

    if (!line.trim()) {
      closeLists();
      continue;
    }

    if (/^\s{0,3}(\*\s*){3,}$|^\s{0,3}(-\s*){3,}$|^\s{0,3}(_\s*){3,}$/.test(line)) {
      closeLists();
      html.push('<hr>');
      continue;
    }

    const heading = line.match(/^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/);
    if (heading) {
      closeLists();
      const level = heading[1].length;
      const text = heading[2];
      html.push(`<h${level} id="${escapeHtml(slugify(text))}">${renderInline(text)}</h${level}>`);
      continue;
    }

    if (/^\s{0,3}>\s?/.test(line)) {
      closeLists();
      const buffer = [];
      while (i < lines.length && /^\s{0,3}>\s?/.test(lines[i])) {
        buffer.push(lines[i].replace(/^\s{0,3}>\s?/, ''));
        i += 1;
      }
      i -= 1;
      html.push(`<blockquote>${renderMarkdown(buffer.join('\n'))}</blockquote>`);
      continue;
    }

    const listItem = line.match(/^(\s*)([-+*]|\d+[.)])\s+(.*)$/);
    if (listItem) {
      const indent = listItem[1].replace(/\t/g, '    ').length;
      const ordered = /\d/.test(listItem[2]);
      const tag = ordered ? 'ol' : 'ul';
      const depth = Math.floor(indent / 2) + 1;

      while (listStack.length > depth) html.push(`</${listStack.pop().tag}>`);
      if (listStack.length === depth && listStack[depth - 1].tag !== tag) {
        html.push(`</${listStack.pop().tag}>`);
      }
      while (listStack.length < depth) {
        listStack.push({ tag });
        html.push(`<${tag}>`);
      }

      const task = listItem[3].match(/^\[([ xX])\]\s+(.*)$/);
      if (task) {
        const checked = task[1].toLowerCase() === 'x' ? ' checked' : '';
        html.push(`<li class="task"><input type="checkbox" disabled${checked}> ${renderInline(task[2])}</li>`);
      } else {
        html.push(`<li>${renderInline(listItem[3])}</li>`);
      }
      continue;
    }

    if (line.includes('|') && i + 1 < lines.length && isTableDelimiter(lines[i + 1])) {
      closeLists();
      const rows = [line, lines[i + 1]];
      i += 2;
      while (i < lines.length && lines[i].includes('|') && lines[i].trim()) {
        rows.push(lines[i]);
        i += 1;
      }
      i -= 1;
      html.push(renderTable(rows));
      continue;
    }

    closeLists();
    const paragraph = [line];
    while (
      i + 1 < lines.length &&
      lines[i + 1].trim() &&
      !/^\s{0,3}(#{1,6}\s|>|```|~~~)/.test(lines[i + 1]) &&
      !/^(\s*)([-+*]|\d+[.)])\s+/.test(lines[i + 1])
    ) {
      i += 1;
      paragraph.push(lines[i]);
    }
    html.push(`<p>${renderInline(paragraph.join('\n'))}</p>`);
  }

  closeLists();
  return html.join('\n');
}

/** Headings, for the outline panel. */
export function extractOutline(source) {
  const outline = [];
  const lines = String(source ?? '').replace(/\r\n?/g, '\n').split('\n');
  let inFence = false;
  lines.forEach((line, index) => {
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence;
      return;
    }
    if (inFence) return;
    const heading = line.match(/^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/);
    if (heading) {
      outline.push({ level: heading[1].length, text: heading[2], line: index + 1, id: slugify(heading[2]) });
    }
  });
  return outline;
}
