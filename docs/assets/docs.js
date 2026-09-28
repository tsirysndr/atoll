/* ------------------------------ theme ---------------------------------- */

const root = document.documentElement;

function currentTheme() {
  return root.dataset.theme === "light" ? "light" : "dark";
}

document.querySelector(".theme-toggle")?.addEventListener("click", () => {
  const next = currentTheme() === "dark" ? "light" : "dark";
  root.dataset.theme = next;
  try {
    localStorage.setItem("atoll-theme", next);
  } catch { /* private mode */ }
});

/* --------------------------- mobile navigation -------------------------- */

const sidebar = document.querySelector(".sidebar");
const scrim = document.querySelector(".sidebar-scrim");
const navToggle = document.querySelector(".nav-toggle");

function setNav(open) {
  sidebar?.classList.toggle("is-open", open);
  if (scrim) scrim.hidden = !open;
  navToggle?.setAttribute("aria-expanded", String(open));
}

navToggle?.addEventListener("click", () => {
  setNav(!sidebar?.classList.contains("is-open"));
});
scrim?.addEventListener("click", () => setNav(false));
sidebar?.addEventListener("click", (event) => {
  if (event.target.closest("a")) setNav(false);
});

document.querySelector('.sidebar a[aria-current="page"]')
  ?.scrollIntoView({ block: "nearest" });

/* ------------------------- table-of-contents spy ------------------------ */

const tocLinks = [...document.querySelectorAll("#toc-list a")];

if (tocLinks.length) {
  const byId = new Map(
    tocLinks.map((link) => [decodeURIComponent(link.hash.slice(1)), link]),
  );
  const headings = [...byId.keys()]
    .map((id) => document.getElementById(id))
    .filter(Boolean);

  let active = null;
  const setActive = (id) => {
    if (id === active) return;
    active = id;
    for (const link of tocLinks) link.classList.remove("is-active");
    byId.get(id)?.classList.add("is-active");
  };

  const observer = new IntersectionObserver((entries) => {
      const visible = entries
      .filter((entry) => entry.isIntersecting)
      .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);

    if (visible.length) {
      setActive(visible[0].target.id);
      return;
    }
    const passed = headings.filter((h) => h.getBoundingClientRect().top < 120);
    if (passed.length) setActive(passed[passed.length - 1].id);
  }, { rootMargin: "-80px 0px -70% 0px", threshold: 0 });

  for (const heading of headings) observer.observe(heading);
}

/* -------------------------- copy code buttons --------------------------- */

for (const pre of document.querySelectorAll(".prose pre")) {
  const code = pre.querySelector("code");
  if (!code) continue;

  const button = document.createElement("button");
  button.type = "button";
  button.className = "copy-button";
  button.textContent = "Copy";
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(code.textContent ?? "");
      button.textContent = "Copied";
      button.classList.add("is-copied");
    } catch {
      button.textContent = "Press ⌘C";
    }
    setTimeout(() => {
      button.textContent = "Copy";
      button.classList.remove("is-copied");
    }, 1600);
  });
  pre.appendChild(button);
}

/* ------------------------------- search --------------------------------- */

const dialog = document.querySelector(".search-dialog");
const input = document.querySelector(".search-input");
const results = document.querySelector(".search-results");
const empty = document.querySelector(".search-empty");

let index = null;
let indexPromise = null;
let selected = 0;

function loadIndex() {
  indexPromise ??= fetch("/search-index.json")
    .then((response) => response.json())
    .then((data) => (index = data))
    .catch(() => (index = []));
  return indexPromise;
}

function openSearch() {
  if (!dialog || dialog.open) return;
  loadIndex();
  dialog.showModal();
  input.value = "";
  render([]);
  input.focus();
}

document.querySelector(".search-trigger")?.addEventListener("click", openSearch);

document.addEventListener("keydown", (event) => {
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(event.target.tagName) ||
    event.target.isContentEditable;

  if (!typing && (event.key === "/" || (event.key === "k" && (event.metaKey || event.ctrlKey)))) {
    event.preventDefault();
    openSearch();
  } else if (event.key === "k" && (event.metaKey || event.ctrlKey)) {
    event.preventDefault();
    openSearch();
  }
});

function tokenize(query) {
  return query.toLowerCase().split(/\s+/).filter((term) => term.length > 1);
}

function score(record, terms) {
  const title = record.title.toLowerCase();
  const section = record.section.toLowerCase();
  const text = record.text.toLowerCase();

  let total = 0;
  for (const term of terms) {
    let hit = 0;
    if (title.includes(term)) hit += 12;
    if (section.includes(term)) hit += 8;

    const occurrences = text.split(term).length - 1;
    if (occurrences) hit += Math.min(occurrences, 5) * 2;

    if (!hit) return 0;
    total += hit;
  }
  return total;
}

function excerpt(text, terms) {
  const lower = text.toLowerCase();
  let at = -1;
  for (const term of terms) {
    const found = lower.indexOf(term);
    if (found !== -1 && (at === -1 || found < at)) at = found;
  }
  const start = Math.max(0, at - 60);
  const slice = text.slice(start, start + 220);
  return (start > 0 ? "…" : "") + slice + (start + 220 < text.length ? "…" : "");
}

function escapeHtml(value) {
  return value.replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

function highlight(text, terms) {
  const pattern = terms
    .map((term) => term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .join("|");
  return escapeHtml(text).replace(
    new RegExp(`(${pattern})`, "gi"),
    "<mark>$1</mark>",
  );
}

function render(hits, terms = []) {
  if (!results || !empty) return;
  selected = 0;

  if (!hits.length) {
    results.innerHTML = "";
    empty.hidden = false;
    empty.textContent = terms.length
      ? "No matches. Try a different word."
      : "Type to search across every page.";
    return;
  }

  empty.hidden = true;
  results.innerHTML = hits.map((hit, i) => `
    <a class="search-hit${i === 0 ? " is-selected" : ""}"
       href="${hit.url}${hit.anchor ? "#" + hit.anchor : ""}">
      <span class="search-hit-crumb">${escapeHtml(hit.title)}</span>
      <span class="search-hit-title">${highlight(hit.section, terms)}</span>
      <p class="search-hit-text">${highlight(excerpt(hit.text, terms), terms)}</p>
    </a>`).join("");
}

input?.addEventListener("input", async () => {
  const terms = tokenize(input.value);
  if (!terms.length) return render([]);

  await loadIndex();
  const hits = (index ?? [])
    .map((record) => ({ record, points: score(record, terms) }))
    .filter((entry) => entry.points > 0)
    .sort((a, b) => b.points - a.points)
    .slice(0, 20)
    .map((entry) => entry.record);

  render(hits, terms);
});

dialog?.addEventListener("keydown", (event) => {
  const hits = [...dialog.querySelectorAll(".search-hit")];
  if (!hits.length) return;

  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    hits[selected]?.classList.remove("is-selected");
    selected = (selected + (event.key === "ArrowDown" ? 1 : hits.length - 1)) % hits.length;
    hits[selected].classList.add("is-selected");
    hits[selected].scrollIntoView({ block: "nearest" });
  } else if (event.key === "Enter" && document.activeElement === input) {
    event.preventDefault();
    hits[selected]?.click();
  }
});
