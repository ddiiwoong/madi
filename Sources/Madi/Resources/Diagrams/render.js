"use strict";
// DiagramRenderer.swift가 부른다. 원문은 인자로 받는다 — 코드에 끼워 넣지 않는다.
//
// 돌려주는 것은 그린 상자의 자리와 크기다. 앱이 그 자리를 PDF로 받는다.
// 원문이 틀리면 Mermaid·KaTeX의 오류를 그대로 던진다 — 앱이 기록 창에 그 문장을 남긴다.

let counter = 0;

async function renderBlock(kind, source, dark, fontSize, color, fontFamily) {
  const out = document.getElementById("out");
  out.innerHTML = "";
  out.style.fontSize = fontSize + "px";
  out.style.color = color;
  out.style.fontFamily = fontFamily;

  if (kind === "math") {
    // trust: false — \href·\includegraphics 같은 바깥을 부르는 명령을 받지 않는다.
    katex.render(source, out, { displayMode: true, throwOnError: true, output: "html", trust: false });
  } else {
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",        // 라벨의 HTML·스크립트·click 동작을 걷어 낸다
      theme: dark ? "dark" : "default",
      fontFamily: fontFamily,
      themeVariables: { fontFamily: fontFamily },
      // 간트는 그릴 자리의 폭을 그대로 쓴다. 숨은 페이지의 폭(1200)을 따라가면 글 넓이로
      // 줄일 때 글자가 작아진다 — 본문 글 넓이쯤으로 정해 둔다.
      gantt: { useWidth: 800 },
    });
    counter += 1;
    const result = await mermaid.render("madi-diagram-" + counter, source);
    out.innerHTML = result.svg;
    // Mermaid는 그림을 width="100%"로 준다. 그대로 두면 상자가 페이지 폭을 따라가므로
    // 그림 자신의 크기(viewBox)로 고정한다.
    const svg = out.querySelector("svg");
    const box = svg && svg.viewBox && svg.viewBox.baseVal;
    if (box && box.width > 0) {
      svg.removeAttribute("width");
      svg.style.maxWidth = "none";
      svg.style.width = box.width + "px";
      svg.style.height = box.height + "px";
    }
  }

  // 글꼴 받기는 레이아웃이 시작한다. 먼저 재게 하고 기다려야 한다 — 그러지 않으면
  // fonts.ready가 받기 전에 끝나 수식이 글꼴 없이 찍힌다(실측: ∫·e·π가 빠졌다).
  out.getBoundingClientRect();
  await document.fonts.ready;
  const rect = out.getBoundingClientRect();
  return { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
}
