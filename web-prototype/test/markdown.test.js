import test from 'node:test';
import assert from 'node:assert/strict';

import { escapeHtml, extractOutline, renderMarkdown, slugify } from '../src/markdown.js';

test('baseline: ordinary markdown renders', () => {
  const html = renderMarkdown('# Title\n\nSome **bold** text.');
  assert.match(html, /<h1 id="title">Title<\/h1>/);
  assert.match(html, /<strong>bold<\/strong>/);
});

test('raw HTML in the source is escaped, never emitted', () => {
  const html = renderMarkdown('<img src=x onerror=alert(1)>\n\n<script>alert(1)</script>');
  // The dangerous strings may appear as escaped TEXT; what must not exist is a
  // live element, i.e. an unescaped '<' followed by a tag name.
  assert.ok(!/<script/i.test(html), 'a script tag reached the output');
  assert.ok(!/<img/i.test(html), 'an img tag reached the output');
  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;/);
});

test('javascript: and data: URLs are refused in links', () => {
  const html = renderMarkdown('[click](javascript:alert(1)) and ![x](data:text/html,<b>)');
  assert.ok(!/href="javascript:/i.test(html), 'a javascript: href was emitted');
  assert.ok(!/src="data:/i.test(html), 'a data: src was emitted');
});

test('relative and mailto links still work', () => {
  const html = renderMarkdown('[doc](./other.md) [mail](mailto:a@example.com)');
  assert.match(html, /href="\.\/other\.md"/);
  assert.match(html, /href="mailto:a@example\.com"/);
});

test('fenced code keeps its content verbatim and escaped', () => {
  const html = renderMarkdown('```js\nconst a = 1 < 2 && "x";\n```');
  assert.match(html, /<pre><code class="language-js">/);
  assert.match(html, /1 &lt; 2 &amp;&amp; &quot;x&quot;/);
});

test('inline code is not further parsed', () => {
  const html = renderMarkdown('use `**not bold**` here');
  assert.match(html, /<code>\*\*not bold\*\*<\/code>/);
  assert.ok(!html.includes('<strong>not bold</strong>'));
});

test('lists, tasks and nesting', () => {
  const html = renderMarkdown('- one\n- two\n  - nested\n\n1. first\n2. second');
  assert.match(html, /<ul>[\s\S]*<li>one<\/li>/);
  assert.match(html, /<ul>[\s\S]*<li>nested<\/li>[\s\S]*<\/ul>/);
  assert.match(html, /<ol>[\s\S]*<li>first<\/li>/);

  const tasks = renderMarkdown('- [x] done\n- [ ] todo');
  assert.match(tasks, /<input type="checkbox" disabled checked>/);
  assert.match(tasks, /<input type="checkbox" disabled>/);
});

test('tables render with alignment', () => {
  const html = renderMarkdown('| a | b |\n| :-- | --: |\n| 1 | 2 |');
  assert.match(html, /<table>/);
  assert.match(html, /<th>a<\/th>/);
  assert.match(html, /<td style="text-align:right">2<\/td>/);
});

test('blockquotes nest their own markdown', () => {
  const html = renderMarkdown('> **quoted**');
  assert.match(html, /<blockquote>[\s\S]*<strong>quoted<\/strong>/);
});

test('outline skips headings inside fenced code', () => {
  const outline = extractOutline('# Real\n\n```\n# Fake\n```\n\n## Second');
  assert.deepEqual(outline.map((h) => h.text), ['Real', 'Second']);
  assert.deepEqual(outline.map((h) => h.level), [1, 2]);
  assert.equal(outline[1].line, 7);
});

test('slugify keeps Korean and drops punctuation', () => {
  assert.equal(slugify('검색 기능 조사!'), '검색-기능-조사');
  assert.equal(escapeHtml('<&>'), '&lt;&amp;&gt;');
});
