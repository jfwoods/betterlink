import { writeFileSync } from 'fs';
const n = v => Number(v).toFixed(3);
const D = Math.PI / 180;

// Option F geometry, with the defaults saved on the canvas
const markColor = '#8EFBC7', outlineColor = '#8EFBC7', plateColor = '#1A1D23';
const gap = 12, band = 5, valley = 11, spread = 65, arcGap = 70, tileRadius = 29;

const od = 80, w = od * 0.125, r = od * 0.4375;
const rOut = r + w / 2, rIn = r - w / 2;
const cy = 100, half = arcGap / 2, dx = spread / 2, cxL = 100 - dx, cxR = 100 + dx;
const P = (cx, R, deg) => n(cx + R * Math.cos(deg * D)) + ' ' + n(cy + R * Math.sin(deg * D));

const markPath = (() => {
  const a1 = 90 + half, a2 = 90 - half;
  const k = rOut + valley, h = Math.sqrt(Math.max(1, k * k - dx * dx));
  const tx = (rOut * dx) / k, ty = cy - (rOut * h) / k;
  const c = Math.sqrt(Math.max(1, rOut * rOut - dx * dx));
  return ['M ' + P(cxL, rOut, a1),
    'A ' + n(rOut) + ' ' + n(rOut) + ' 0 1 1 ' + n(cxL + tx) + ' ' + n(ty),
    'A ' + n(valley) + ' ' + n(valley) + ' 0 0 0 ' + n(cxR - tx) + ' ' + n(ty),
    'A ' + n(rOut) + ' ' + n(rOut) + ' 0 1 1 ' + P(cxR, rOut, a2),
    'L ' + P(cxR, rIn, a2),
    'A ' + n(rIn) + ' ' + n(rIn) + ' 0 1 0 ' + P(cxR, rIn, a1),
    'L ' + P(cxR, rOut, a1),
    'A ' + n(rOut) + ' ' + n(rOut) + ' 0 0 0 100 ' + n(cy + c),
    'A ' + n(rOut) + ' ' + n(rOut) + ' 0 0 0 ' + P(cxL, rOut, a2),
    'L ' + P(cxL, rIn, a2),
    'A ' + n(rIn) + ' ' + n(rIn) + ' 0 1 0 ' + P(cxL, rIn, a1),
    'Z'].join(' ');
})();

const contour = (off) => {
  const R = rOut + off, rv = Math.max(1, valley - off);
  const k = R + rv, h = Math.sqrt(Math.max(1, k * k - dx * dx));
  const tx = (R * dx) / k, ty = cy - (R * h) / k;
  return ['M ' + P(cxL, R, 90),
    'A ' + n(R) + ' ' + n(R) + ' 0 1 1 ' + n(cxL + tx) + ' ' + n(ty),
    'A ' + n(rv) + ' ' + n(rv) + ' 0 0 0 ' + n(cxR - tx) + ' ' + n(ty),
    'A ' + n(R) + ' ' + n(R) + ' 0 1 1 ' + P(cxR, R, 90),
    'Z'].join(' ');
};

const art = `  <g transform="rotate(90 100 100)">
    <path d="${contour(gap + band)}" fill="${outlineColor}"/>
    <path d="${contour(gap)}" fill="${plateColor}"/>
    <path d="${markPath}" fill="${markColor}"/>
  </g>`;

// HIG (App icons): macOS icons are square and UNMASKED - the system applies the
// rounded-corner shape. Art stays inside the 824/1024 content grid so the system
// mask never clips it.
const BODY = 824, ORIGIN = 100;
const icon = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect width="1024" height="1024" fill="${plateColor}"/>
  <g transform="translate(${ORIGIN} ${ORIGIN}) scale(${BODY / 200})">
${art}
  </g>
</svg>
`;
const glyph = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 200 200">
${art}
</svg>
`;

writeFileSync('AppIcon.svg', icon);
writeFileSync('BetterlinkMark.svg', glyph);
writeFileSync('preview.html', `<body style="margin:0;width:1024px;height:1024px;overflow:hidden;background:${plateColor}">${icon}</body>`);
console.log('wrote AppIcon.svg + BetterlinkMark.svg');
