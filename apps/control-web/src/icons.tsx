// Icones em SVG inline (sem bibliotecas nem recursos externos).
const base = { width: 16, height: 16, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.8, strokeLinecap: "round", strokeLinejoin: "round" } as const;

export const IconServer = () => (
  <svg {...base} aria-hidden>
    <rect x="3" y="4" width="18" height="7" rx="1.5" />
    <rect x="3" y="13" width="18" height="7" rx="1.5" />
    <path d="M7 7.5h.01M7 16.5h.01" />
  </svg>
);
export const IconBox = () => (
  <svg {...base} aria-hidden>
    <path d="M21 8 12 3 3 8v8l9 5 9-5V8Z" />
    <path d="m3 8 9 5 9-5M12 13v8" />
  </svg>
);
export const IconPulse = () => (
  <svg {...base} aria-hidden>
    <path d="M3 12h4l2-6 4 12 2-6h6" />
  </svg>
);
export const IconArchive = () => (
  <svg {...base} aria-hidden>
    <rect x="3" y="4" width="18" height="5" rx="1" />
    <path d="M5 9v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9M10 13h4" />
  </svg>
);
export const IconAlert = () => (
  <svg {...base} aria-hidden>
    <path d="M12 3 2 20h20L12 3Z" />
    <path d="M12 10v4M12 17h.01" />
  </svg>
);
export const IconRefresh = ({ spin = false }: { spin?: boolean }) => (
  <svg {...base} aria-hidden className={spin ? "animate-spin" : undefined}>
    <path d="M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7" />
  </svg>
);
export const IconShield = () => (
  <svg {...base} aria-hidden>
    <path d="M12 3 4 6v6c0 4.5 3.4 8.3 8 9 4.6-.7 8-4.5 8-9V6l-8-3Z" />
  </svg>
);
