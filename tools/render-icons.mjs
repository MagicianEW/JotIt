#!/usr/bin/env node
//
// Renders the JotIt launcher icon for every platform.
//
// The icon is a sheet of paper with a J cut out of it, sitting on the app's
// pine green. The cut-out is the whole idea: the hole is what makes it
// JotIt and not a generic note app, and it only works because the tile
// behind carries a gradient — a flat green painted over the page would look
// like a sticker, a hole lets the gradient through.
//
// Everything is generated from one set of numbers, so the icon on macOS, on
// Windows and on Android is the same drawing at different sizes and masks.
// Change a number here, re-run, and every platform moves together.
//
// Usage: node tools/render-icons.mjs [--variant sage|gold|paper]
//
// Requires Google Chrome for rasterising the SVG (the same engine that
// renders the app, so what you see here is what you get).
//
// After rebuilding the macOS app **in place**, the Dock keeps showing the
// old icon: macOS caches icons per bundle path, and rebuilding the bundle
// does not invalidate the entry. Three commands clear it — the touch is the
// part that matters, because it is the mtime the cache keys on:
//
//   touch build/macos/Build/Products/Release/JotIt.app
//   /System/Library/Frameworks/CoreServices.framework/Frameworks/\
//     LaunchServices.framework/Support/lsregister -f \
//     build/macos/Build/Products/Release/JotIt.app
//   killall Dock
//
// A freshly installed app has no such history and shows the new icon
// straight away.

import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const CHROME =
  process.env.CHROME_PATH ??
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// ---------------------------------------------------------------- palette

const COLORS = {
  tileTop: '#3E7154',
  tileBottom: '#234734',
  paper: '#FAF8F3',
  foldSage: '#CFE6D6',
  foldGold: '#D9C48E',
  pine: '#2E5B43',
  paperTileTop: '#FBF9F5',
  paperTileBottom: '#E7E1D2',
  pineFold: '#9FC6AC',
};

const VARIANTS = {
  sage: {
    tile: [COLORS.tileTop, COLORS.tileBottom],
    page: COLORS.paper,
    fold: COLORS.foldSage,
    label: '松绿底 · 暖纸页 · 浅鼠尾草折角',
  },
  gold: {
    tile: [COLORS.tileTop, COLORS.tileBottom],
    page: COLORS.paper,
    fold: COLORS.foldGold,
    label: '松绿底 · 暖纸页 · 金折角',
  },
  paper: {
    tile: [COLORS.paperTileTop, COLORS.paperTileBottom],
    page: COLORS.pine,
    fold: COLORS.pineFold,
    label: '暖纸底 · 松绿页',
  },
};

// ---------------------------------------------------------------- geometry

// The squircle the whole icon sits on, in a 1024 box.
const TILE_PATH =
  'M0,300 C0,134 134,0 300,0 H724 C890,0 1024,134 1024,300 V724 ' +
  'C1024,890 890,1024 724,1024 H300 C134,1024 0,890 0,724 Z';

// The J, as segments so the same numbers can feed the SVG and the Android
// vector drawable (a vector drawable has no transform, so the placement has
// to be baked into the coordinates).
const J_SEGMENTS = [
  ['M', 570, 256],
  ['L', 570, 580],
  ['Q', 570, 676, 474, 676],
  ['L', 436, 676],
  ['Q', 352, 676, 352, 588],
  ['L', 352, 524],
];
const J_STROKE = 98;

// The J's inked bounding box: the path above, widened by half the stroke
// with the round caps taken into account.
const J_BOX = { x0: 303, y0: 207, x1: 619, y1: 725 };

// The sheet of paper the J is cut out of.
const PAGE = {
  x0: 270,
  y0: 214,
  x1: 754,
  y1: 816,
  foldX: 610,
  foldY: 358,
  r: 44,
};

// How the J sits on the paper: its height and where its centre lands.
const J_PLACEMENT = { height: 420, cx: 470, cy: 515 };

// ---------------------------------------------------------------- helpers

function segmentsToPath(segments) {
  return segments
    .map((seg) => seg[0] + seg.slice(1).map((n) => Math.round(n * 10) / 10).join(' '))
    .join(' ');
}

function transformSegments(segments, tx, ty, scale) {
  return segments.map((seg) => [
    seg[0],
    ...seg.slice(1).map((n) => Math.round((tx + scale * n) * 100) / 100),
  ]);
}

function placementTransform(placement, box = J_BOX) {
  const scale = placement.height / (box.y1 - box.y0);
  const tx = placement.cx - (scale * (box.x0 + box.x1)) / 2;
  const ty = placement.cy - (scale * (box.y0 + box.y1)) / 2;
  return { scale, tx, ty };
}

function pagePath(p = PAGE) {
  return (
    `M${p.x0},${p.y0} H${p.foldX} L${p.x1},${p.foldY} V${p.y1 - p.r} ` +
    `A${p.r},${p.r} 0 0 1 ${p.x1 - p.r},${p.y1} H${p.x0 + p.r} ` +
    `A${p.r},${p.r} 0 0 1 ${p.x0},${p.y1 - p.r} Z`
  );
}

function foldPath(p = PAGE) {
  return (
    `M${p.foldX},${p.y0} L${p.x1},${p.foldY} H${p.x1 - 100} ` +
    `Q${p.foldX},${p.foldY} ${p.foldX},${p.foldY - 100} Z`
  );
}

// ---------------------------------------------------------------- svg parts

function tileGradient(variant, id) {
  const [top, bottom] = variant.tile;
  return (
    `<linearGradient id="${id}" x1="0.1" y1="0" x2="0.6" y2="1">` +
    `<stop offset="0" stop-color="${top}"/>` +
    `<stop offset="1" stop-color="${bottom}"/>` +
    `</linearGradient>`
  );
}

/** The tile alone — the background of an adaptive icon, or the macOS plate. */
function tileOnly(variant, { shadow = false, scale = 1, offset = 0 } = {}) {
  const filter = shadow
    ? `<filter id="sh" x="-25%" y="-25%" width="150%" height="150%">` +
      `<feDropShadow dx="0" dy="16" stdDeviation="24" flood-color="#08150F" flood-opacity="0.32"/>` +
      `</filter>`
    : '';
  const transform = `translate(${offset},${offset}) scale(${scale})`;
  return (
    `<g transform="${transform}">` +
    (filter ? `<defs>${filter}</defs>` : '') +
    `<path d="${TILE_PATH}" fill="url(#tile)"${shadow ? ' filter="url(#sh)"' : ''}/>` +
    `</g>`
  );
}

/** The paper with the J cut out of it, on transparency. */
function pageWithCutout(variant, placement = J_PLACEMENT) {
  const { scale, tx, ty } = placementTransform(placement);
  const jPath = segmentsToPath(J_SEGMENTS);
  const jTransform = `translate(${tx.toFixed(2)},${ty.toFixed(2)}) scale(${scale.toFixed(5)})`;
  return (
    `<defs>` +
    `<mask id="cut">` +
    `<rect x="0" y="0" width="1024" height="1024" fill="#fff"/>` +
    `<g transform="${jTransform}">` +
    `<path d="${jPath}" fill="none" stroke="#000" stroke-width="${J_STROKE}" ` +
    `stroke-linecap="round" stroke-linejoin="round"/>` +
    `</g>` +
    `</mask>` +
    `</defs>` +
    `<g mask="url(#cut)">` +
    `<path d="${pagePath()}" fill="${variant.page}"/>` +
    `<path d="${foldPath()}" fill="${variant.fold}"/>` +
    `</g>`
  );
}

/** The whole tile: background, page, cut-out. */
function fullTile(variant, options = {}) {
  const { scale = 1, offset = 0, shadow = false } = options;
  const inner = tileOnly(variant, { shadow, scale: 1, offset: 0 }) +
    pageWithCutout(variant);
  const transform = scale === 1 && offset === 0
    ? inner
    : `<g transform="translate(${offset},${offset}) scale(${scale})">${inner}</g>`;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">` +
    `<defs>${tileGradient(variant, 'tile')}</defs>` +
    transform +
    `</svg>`
  );
}

// ---------------------------------------------------------------- raster

function renderPng(svg, size, outPath) {
  const html =
    `<!doctype html><meta charset="utf-8">` +
    `<style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}` +
    `svg{display:block;width:${size}px;height:${size}px}</style>` +
    svg;
  const tmp = join(tmpdir(), `jotit_icon_${Date.now()}_${size}.html`);
  writeFileSync(tmp, html);
  try {
    execFileSync(
      CHROME,
      [
        '--headless',
        '--disable-gpu',
        '--hide-scrollbars',
        '--default-background-color=00000000',
        '--force-device-scale-factor=1',
        `--window-size=${size},${size}`,
        `--screenshot=${outPath}`,
        `file://${tmp}`,
      ],
      { stdio: ['ignore', 'ignore', 'pipe'] },
    );
  } finally {
    rmSync(tmp, { force: true });
  }
  if (!existsSync(outPath)) {
    throw new Error(`Chrome did not produce ${outPath}`);
  }
}

// ---------------------------------------------------------------- ico

function packIco(entries) {
  // ICO with PNG payloads: Vista and later read these happily, and it keeps
  // the alpha channel that the .ico format otherwise cannot carry.
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0); // reserved
  header.writeUInt16LE(1, 2); // 1 = icon
  header.writeUInt16LE(entries.length, 4);

  const directory = Buffer.alloc(16 * entries.length);
  let offset = header.length + directory.length;
  entries.forEach((entry, index) => {
    const at = index * 16;
    directory.writeUInt8(entry.size >= 256 ? 0 : entry.size, at);
    directory.writeUInt8(entry.size >= 256 ? 0 : entry.size, at + 1);
    directory.writeUInt8(0, at + 2); // palette size
    directory.writeUInt8(0, at + 3); // reserved
    directory.writeUInt16LE(1, at + 4); // colour planes
    directory.writeUInt16LE(32, at + 6); // bits per pixel
    directory.writeUInt32LE(entry.data.length, at + 8);
    directory.writeUInt32LE(offset, at + 12);
    offset += entry.data.length;
  });

  return Buffer.concat([header, directory, ...entries.map((e) => e.data)]);
}

// ---------------------------------------------------------------- outputs

const variantName =
  process.argv.includes('--variant')
    ? process.argv[process.argv.indexOf('--variant') + 1]
    : 'sage';
const variant = VARIANTS[variantName];
if (!variant) {
  throw new Error(
    `unknown variant "${variantName}" (have: ${Object.keys(VARIANTS).join(', ')})`,
  );
}

function ensure(dir) {
  mkdirSync(dir, { recursive: true });
}

// -- the source of truth, kept in the repo ---------------------------------
const sourceDir = join(repo, 'design', 'icon');
ensure(sourceDir);
writeFileSync(join(sourceDir, 'jotit-icon.svg'), fullTile(variant));
writeFileSync(
  join(sourceDir, 'jotit-icon-page.svg'),
  `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">` +
    pageWithCutout(variant) +
    `</svg>`,
);
writeFileSync(
  join(sourceDir, 'jotit-icon-j.svg'),
  `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">` +
    `<defs>${tileGradient(variant, 'tile')}</defs>` +
    `<g transform="translate(${placementTransform(J_PLACEMENT).tx.toFixed(2)},` +
    `${placementTransform(J_PLACEMENT).ty.toFixed(2)}) ` +
    `scale(${placementTransform(J_PLACEMENT).scale.toFixed(5)})">` +
    `<path d="${segmentsToPath(J_SEGMENTS)}" fill="none" stroke="${variant.page}" ` +
    `stroke-width="${J_STROKE}" stroke-linecap="round" stroke-linejoin="round"/>` +
    `</g></svg>`,
);

// -- macOS ------------------------------------------------------------------
// Apple's icons are a squircle with a soft shadow, not a full-bleed square:
// the artwork sits in the middle 824 of the 1024 canvas.
const macDir = join(repo, 'macos', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset');
ensure(macDir);
for (const size of [16, 32, 64, 128, 256, 512, 1024]) {
  const margin = (1024 - 824) / 2;
  const scale = 824 / 1024;
  const inner =
    tileOnly(variant, { shadow: true }) + pageWithCutout(variant);
  const wrapped =
    `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">` +
    `<defs>${tileGradient(variant, 'tile')}</defs>` +
    `<g transform="translate(${margin},${margin}) scale(${scale})">${inner}</g>` +
    `</svg>`;
  renderPng(wrapped, size, join(macDir, `app_icon_${size}.png`));
}


// -- Windows ----------------------------------------------------------------
// No mask, no shadow: the .ico is drawn as-is, so the plate fills the square.
const winDir = join(repo, 'windows', 'runner', 'resources');
ensure(winDir);
const winSizes = [16, 24, 32, 48, 64, 128, 256];
const winEntries = [];
for (const size of winSizes) {
  const file = join(tmpdir(), `jotit_win_${size}.png`);
  renderPng(fullTile(variant), size, file);
  winEntries.push({ size, data: readFileSync(file) });
  rmSync(file, { force: true });
}
writeFileSync(join(winDir, 'app_icon.ico'), packIco(winEntries));

// -- Android ----------------------------------------------------------------
const androidRes = join(repo, 'android', 'app', 'src', 'main', 'res');
const legacy = {
  mdpi: 48,
  hdpi: 72,
  xhdpi: 96,
  xxhdpi: 144,
  xxxhdpi: 192,
};
for (const [density, size] of Object.entries(legacy)) {
  const dir = join(androidRes, `mipmap-${density}`);
  ensure(dir);
  renderPng(fullTile(variant), size, join(dir, 'ic_launcher.png'));
}

// The adaptive icon: the pine plate is the background layer, the paper with
// the cut-out is the foreground.
//
// The foreground lives in the middle 66dp of a 108dp canvas, and that safe
// zone is a *circle* — so it is the paper's diagonal, not its width, that
// has to fit. The whole drawing (paper and cut-out together) is scaled down
// to that size and centred; scaling the J on its own would take it off the
// paper.
const adaptive = {
  mdpi: 108,
  hdpi: 162,
  xhdpi: 216,
  xxhdpi: 324,
  xxxhdpi: 432,
};
const PAGE_DIAGONAL = Math.hypot(PAGE.x1 - PAGE.x0, PAGE.y1 - PAGE.y0);
const foregroundScale = (66 * (1024 / 108)) / PAGE_DIAGONAL;
const foregroundTx = 512 - foregroundScale * (PAGE.x0 + PAGE.x1) / 2;
const foregroundTy = 512 - foregroundScale * (PAGE.y0 + PAGE.y1) / 2;
for (const [density, size] of Object.entries(adaptive)) {
  const dir = join(androidRes, `mipmap-${density}`);
  ensure(dir);
  const paper =
    `<g transform="scale(${(size / 1024).toFixed(5)})">` +
    `<g transform="translate(${foregroundTx.toFixed(2)},${foregroundTy.toFixed(2)}) ` +
    `scale(${foregroundScale.toFixed(5)})">` +
    `<defs>` +
    `<mask id="cut">` +
    `<rect x="0" y="0" width="1024" height="1024" fill="#fff"/>` +
    `<g transform="translate(${placementTransform(J_PLACEMENT).tx.toFixed(2)},` +
    `${placementTransform(J_PLACEMENT).ty.toFixed(2)}) ` +
    `scale(${placementTransform(J_PLACEMENT).scale.toFixed(5)})">` +
    `<path d="${segmentsToPath(J_SEGMENTS)}" fill="none" stroke="#000" ` +
    `stroke-width="${J_STROKE}" stroke-linecap="round" stroke-linejoin="round"/>` +
    `</g></mask></defs>` +
    `<g mask="url(#cut)">` +
    `<path d="${pagePath()}" fill="${variant.page}"/>` +
    `<path d="${foldPath()}" fill="${variant.fold}"/>` +
    `</g></g></g>`;
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" ` +
    `viewBox="0 0 ${size} ${size}">${paper}</svg>`;
  renderPng(svg, size, join(dir, 'ic_launcher_foreground.png'));
}

// The background layer: the pine gradient, full bleed.
ensure(join(androidRes, 'drawable'));
writeFileSync(
  join(androidRes, 'drawable', 'ic_launcher_background.xml'),
  `<?xml version="1.0" encoding="utf-8"?>
<!-- The pine plate the paper sits on. A gradient, because the cut-out in the
     foreground lets this show through the J — a flat colour would make the
     hole look like a sticker. -->
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <gradient
        android:startColor="${variant.tile[0]}"
        android:endColor="${variant.tile[1]}"
        android:angle="315" />
</shape>
`,
);

// The themed icon (Android 13+): one flat silhouette the system tints.
// The J alone — a page shape the system could not tint cleanly would be a
// slab of colour, and the glyph is what carries the idea anyway.
//
// The numbers here are viewport units (the canvas is 108 across), not the
// 1024 space the rest of the drawing uses.
const themedScale = 58 / (J_BOX.y1 - J_BOX.y0);
const themedTx = 54 - (themedScale * (J_BOX.x0 + J_BOX.x1)) / 2;
const themedTy = 54 - (themedScale * (J_BOX.y0 + J_BOX.y1)) / 2;
const themedSegments = transformSegments(J_SEGMENTS, themedTx, themedTy, themedScale);
writeFileSync(
  join(androidRes, 'drawable', 'ic_launcher_monochrome.xml'),
  `<?xml version="1.0" encoding="utf-8"?>
<!-- The themed icon's silhouette: the J, and only the J. The system tints
     whatever it finds here, so this has to be one flat shape. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:pathData="${segmentsToPath(themedSegments)}"
        android:strokeColor="#000000"
        android:strokeWidth="${(J_STROKE * themedScale).toFixed(3)}"
        android:strokeLineCap="round"
        android:strokeLineJoin="round" />
</vector>
`,
);

// The adaptive icon itself.
ensure(join(androidRes, 'mipmap-anydpi-v26'));
writeFileSync(
  join(androidRes, 'mipmap-anydpi-v26', 'ic_launcher.xml'),
  `<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
`,
);
ensure(join(androidRes, 'mipmap-anydpi-v33'));
writeFileSync(
  join(androidRes, 'mipmap-anydpi-v33', 'ic_launcher.xml'),
  `<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
`,
);

console.log(`rendered the "${variantName}" icon: ${variant.label}`);
console.log('  design/icon/jotit-icon.svg');
console.log('  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png');
console.log('  windows/runner/resources/app_icon.ico');
console.log('  android/app/src/main/res/mipmap-*/ic_launcher*.png');
console.log('  android/app/src/main/res/mipmap-anydpi-v26|v33/ic_launcher.xml');
console.log('  android/app/src/main/res/drawable/ic_launcher_{background,monochrome}.xml');
