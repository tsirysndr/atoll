/// The backdrop behind sign-in and sign-up.
///
/// Drawn as a flat scene with bold outlines rather than a gradient wash: a night
/// landscape where a tower broadcasts the plays it has heard, and balloons carry
/// notes up into a sky of sparks. Rocksky scrobbles music, so the picture is
/// about listening being sent somewhere.
///
/// The composition is deliberately empty through the middle, where the card
/// sits, and everything is marked decorative so it never reaches a screen
/// reader or competes with the form.

const INK = "#5c1cb0";
const DEEP = "#47158a";
const MID = "#8338ec";
const SOFT = "#c29dff";
const PALE = "#ece0ff";

export function AuthBackdrop() {
  return (
    <div
      aria-hidden
      // z-0, not a negative index: a child painted at a negative z-index goes
      // behind its parent's background, and `body` has an opaque one, which hid
      // this entirely.
      className="pointer-events-none fixed inset-0 z-0 overflow-hidden bg-[#f6f3ff] dark:bg-[#0f0b18]"
    >
      <svg
        className="h-full w-full opacity-[0.85] dark:opacity-40"
        viewBox="0 0 1200 800"
        preserveAspectRatio="xMidYMid slice"
        role="presentation"
      >
        <defs>
          <linearGradient id="dawn" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#efe4ff" />
            <stop offset="62%" stopColor="#f8f5ff" />
            <stop offset="100%" stopColor="#efe6ff" />
          </linearGradient>
        </defs>

        <rect width="1200" height="800" fill="url(#dawn)" />

        {/* Sky: four-point sparks, outlined, scattered clear of the centre. */}
        <g stroke={MID} strokeWidth="2" strokeLinecap="round" opacity="0.5">
          {SPARKS.map(([x, y, r], i) => (
            <g key={i} transform={`translate(${x} ${y})`}>
              <line x1={-r} y1="0" x2={r} y2="0" />
              <line x1="0" y1={-r} x2="0" y2={r} />
            </g>
          ))}
        </g>

        {/* A moon, with the flat-fill-and-outline treatment. */}
        <g transform="translate(1032 128)">
          <circle r="42" fill={PALE} stroke={INK} strokeWidth="3" />
          <circle cx="-14" cy="-10" r="7" fill={SOFT} opacity="0.8" />
          <circle cx="10" cy="12" r="10" fill={SOFT} opacity="0.65" />
          <circle cx="16" cy="-16" r="4.5" fill={SOFT} opacity="0.7" />
        </g>

        {/* Clouds: stacked lozenges, thick outline, no gradient. */}
        <Cloud x={150} y={168} scale={1.15} />
        <Cloud x={880} y={248} scale={0.8} />
        <Cloud x={420} y={110} scale={0.62} />

        {/* Balloons carrying notes: the playful element, kept to the edges. */}
        <Balloon x={214} y={372} scale={1} note="quaver" />
        <Balloon x={1002} y={416} scale={0.78} note="beamed" />

        {/* Hills, back to front, each a flat fill over a bold edge. */}
        <g>
          <path
            d="M0 612 C 150 560 300 596 440 572 C 600 544 720 596 860 578 C 1000 560 1110 592 1200 572 L1200 800 L0 800 Z"
            fill={SOFT}
            stroke={INK}
            strokeWidth="3"
            opacity="0.55"
          />
          <path
            d="M0 676 C 180 632 320 672 470 650 C 640 624 780 668 930 648 C 1060 630 1140 660 1200 646 L1200 800 L0 800 Z"
            fill={MID}
            stroke={INK}
            strokeWidth="3"
            opacity="0.5"
          />
          <path
            d="M0 736 C 200 706 380 740 560 724 C 760 706 900 738 1060 726 C 1130 720 1170 730 1200 726 L1200 800 L0 800 Z"
            fill={DEEP}
            stroke={INK}
            strokeWidth="3"
            opacity="0.55"
          />
        </g>

        {/* The tower: what a scrobble actually is — a play, sent on. */}
        <g transform="translate(612 560)">
          {/* Broadcast arcs, widening outward. */}
          <g stroke={INK} strokeWidth="2.5" fill="none" strokeLinecap="round" opacity="0.5">
            <path d="M-34 -96 a 46 46 0 0 1 68 0" />
            <path d="M-56 -118 a 76 76 0 0 1 112 0" />
            <path d="M-78 -140 a 106 106 0 0 1 156 0" />
          </g>

          {/* Mast and legs. */}
          <g stroke={INK} strokeWidth="3.5" strokeLinecap="round" fill="none">
            <line x1="0" y1="-84" x2="0" y2="96" />
            <line x1="0" y1="96" x2="-30" y2="148" />
            <line x1="0" y1="96" x2="30" y2="148" />
            <line x1="-15" y1="122" x2="15" y2="122" />
            <line x1="-8" y1="64" x2="8" y2="64" />
            <line x1="-5" y1="26" x2="5" y2="26" />
          </g>
          <circle cy="-88" r="6.5" fill={PALE} stroke={INK} strokeWidth="3" />
        </g>

        {/* The scrobble trace along the foreground: one mark per play. */}
        <g stroke={PALE} strokeWidth="6" strokeLinecap="round" opacity="0.85">
          {PLAYS.map((height, i) => (
            <line
              key={i}
              x1={40 + i * 28}
              y1={782}
              x2={40 + i * 28}
              y2={782 - height}
            />
          ))}
        </g>
        <g stroke={INK} strokeWidth="2" strokeLinecap="round" opacity="0.4">
          {PLAYS.map((height, i) => (
            <line
              key={i}
              x1={40 + i * 28}
              y1={782}
              x2={40 + i * 28}
              y2={782 - height}
            />
          ))}
        </g>
      </svg>
    </div>
  );
}

function Cloud({ x, y, scale }: { x: number; y: number; scale: number }) {
  return (
    <g transform={`translate(${x} ${y}) scale(${scale})`} opacity="0.9">
      <path
        d="M-62 16 a 26 26 0 0 1 4 -51 a 34 34 0 0 1 62 -12 a 28 28 0 0 1 40 14 a 24 24 0 0 1 -6 49 Z"
        fill="#ffffff"
        stroke={INK}
        strokeWidth="3"
        strokeLinejoin="round"
      />
      <path
        d="M-40 2 a 16 16 0 0 1 22 -16"
        fill="none"
        stroke={SOFT}
        strokeWidth="3"
        strokeLinecap="round"
      />
    </g>
  );
}

function Balloon({
  x,
  y,
  scale,
  note,
}: {
  x: number;
  y: number;
  scale: number;
  note: "quaver" | "beamed";
}) {
  return (
    <g transform={`translate(${x} ${y}) scale(${scale})`}>
      {/* Envelope, with two gores picked out in a darker tint. */}
      <path
        d="M0 -74 C 40 -74 62 -44 62 -14 C 62 16 34 44 0 70 C -34 44 -62 16 -62 -14 C -62 -44 -40 -74 0 -74 Z"
        fill={PALE}
        stroke={INK}
        strokeWidth="3.5"
        strokeLinejoin="round"
      />
      <path
        d="M0 -74 C 14 -74 22 -44 22 -14 C 22 16 12 44 0 70 C -12 44 -22 16 -22 -14 C -22 -44 -14 -74 0 -74 Z"
        fill={SOFT}
        opacity="0.75"
      />
      <path
        d="M34 -66 C 54 -52 62 -34 62 -14 C 62 10 44 34 22 56"
        fill="none"
        stroke={INK}
        strokeWidth="2"
        opacity="0.45"
      />

      {/* Basket, slung below. */}
      <g stroke={INK} strokeWidth="2.5" fill="none">
        <line x1="-14" y1="70" x2="-9" y2="86" />
        <line x1="14" y1="70" x2="9" y2="86" />
      </g>
      <rect
        x="-13"
        y="86"
        width="26"
        height="18"
        rx="4"
        fill={MID}
        stroke={INK}
        strokeWidth="3"
      />

      {/* What it carries. */}
      <g fill={DEEP} transform="translate(0 -22)">
        {note === "quaver" ? (
          <g>
            <ellipse cx="-4" cy="10" rx="7.5" ry="5.5" transform="rotate(-18 -4 10)" />
            <rect x="2" y="-16" width="2.6" height="26" rx="1.3" />
            <path d="M4.6 -16 q 11 4 8 14 q -1 -7 -8 -8 Z" />
          </g>
        ) : (
          <g>
            <ellipse cx="-11" cy="12" rx="7" ry="5" transform="rotate(-18 -11 12)" />
            <ellipse cx="15" cy="6" rx="7" ry="5" transform="rotate(-18 15 6)" />
            <rect x="-5" y="-14" width="2.6" height="26" rx="1.3" />
            <rect x="21" y="-20" width="2.6" height="26" rx="1.3" />
            <path d="M-5 -14 L23.6 -20 L23.6 -13 L-5 -7 Z" />
          </g>
        )}
      </g>
    </g>
  );
}

/// Fixed so the sky is the same on every visit: [x, y, arm length].
const SPARKS: [number, number, number][] = [
  [78, 92, 7], [196, 74, 5], [300, 206, 6], [368, 56, 4],
  [486, 188, 5], [560, 70, 7], [700, 150, 5], [792, 78, 6],
  [900, 142, 4], [964, 300, 5], [1090, 84, 7], [1154, 210, 5],
  [120, 268, 5], [262, 330, 4], [1128, 330, 6], [48, 420, 4],
  [1176, 452, 5], [340, 452, 4], [860, 392, 5],
];

/// Bar heights for the foreground trace, rising toward the present.
const PLAYS = [
  10, 16, 13, 22, 18, 27, 21, 32, 25, 38, 29, 43, 33, 49, 37, 54, 41, 60,
  45, 65, 49, 71, 53, 76, 57, 82, 61, 87, 65, 93, 69, 98, 73, 104, 77, 109,
  81, 115, 85, 120, 89, 126,
];
