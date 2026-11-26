// 시험용 HTML 나무 — 브라우저의 `DOMParser`가 없어 `@lezer/html`(편집기가 이미 쓰는 문법)로 읽어 `PasteNode`로 짓는다. 엔터티는 시험에
// 나오는 것만 푼다. 브라우저와 달리 `<html>` · `<body>`를 보태지 않는다 — 변환은 둘 다 감싸는 블록으로 읽는다.

import { parser } from "@lezer/html";
import type { SyntaxNode } from "@lezer/common";
import type { PasteNode } from "../src/core/richpaste.ts";

class FakeNode implements PasteNode {
  readonly nodeType: number;
  readonly nodeName: string;
  readonly nodeValue: string | null;
  readonly childNodes: FakeNode[] = [];
  private readonly attributes = new Map<string, string>();

  constructor(nodeType: number, nodeName: string, nodeValue: string | null = null) {
    this.nodeType = nodeType;
    this.nodeName = nodeName;
    this.nodeValue = nodeValue;
  }

  getAttribute(name: string): string | null {
    return this.attributes.get(name.toLowerCase()) ?? null;
  }

  setAttribute(name: string, value: string): void {
    this.attributes.set(name.toLowerCase(), value);
  }
}

const named: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: "\u00a0", middot: "·", hellip: "…" };

function decode(text: string): string {
  return text.replace(/&(#x[\da-f]+|#\d+|[a-z]+);/gi, (whole, name: string) => {
    if (name.startsWith("#x") || name.startsWith("#X")) return String.fromCodePoint(Number.parseInt(name.slice(2), 16));
    if (name.startsWith("#")) return String.fromCodePoint(Number.parseInt(name.slice(1), 10));
    return named[name.toLowerCase()] ?? whole;
  });
}

export function parseHtml(source: string): PasteNode {
  const root = new FakeNode(9, "#document");
  fill(root, parser.parse(source).topNode, source, 0, source.length);
  return root;
}

/** `from`~`to` 사이의 자식 — 요소 · 주석은 따로, 나머지(글 · 엔터티 · 요소 사이의 빈칸)는 글 마디로. */
function fill(target: FakeNode, node: SyntaxNode, source: string, from: number, to: number): void {
  let text = "";
  let cursor = from;
  const flush = () => {
    if (text !== "") target.childNodes.push(new FakeNode(3, "#text", decode(text)));
    text = "";
  };
  for (let child = node.firstChild; child; child = child.nextSibling) {
    if (child.to <= from || child.from >= to) continue;
    if (child.name === "Element" || child.name === "Comment") {
      text += source.slice(cursor, child.from);
      flush();
      target.childNodes.push(child.name === "Comment" ? new FakeNode(8, "#comment", source.slice(child.from, child.to)) : element(child, source));
      cursor = child.to;
    }
  }
  text += source.slice(cursor, to);
  flush();
}

function element(node: SyntaxNode, source: string): FakeNode {
  const open = node.getChild("OpenTag") ?? node.getChild("SelfClosingTag");
  const close = node.getChild("CloseTag");
  const nameNode = open?.getChild("TagName");
  const made = new FakeNode(1, nameNode ? source.slice(nameNode.from, nameNode.to).toUpperCase() : "UNKNOWN");
  for (const attribute of open?.getChildren("Attribute") ?? []) {
    const name = attribute.getChild("AttributeName");
    const value = attribute.getChild("AttributeValue") ?? attribute.getChild("UnquotedAttributeValue");
    if (!name) continue;
    const raw = value ? source.slice(value.from, value.to) : "";
    made.setAttribute(source.slice(name.from, name.to), decode(raw.replace(/^(["'])([\s\S]*)\1$/, "$2")));
  }
  if (open?.name === "OpenTag") fill(made, node, source, open.to, close ? close.from : node.to);
  return made;
}
