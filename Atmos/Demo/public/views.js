const iconPaths = {
  calendar: '<rect x="3" y="5" width="18" height="16" rx="3"/><path d="M7 3v4m10-4v4M3 10h18"/>',
  event: '<path d="M4 21h16M6 21V6l8-3v18m0-13h4v13M9 9v2m0 3v2m7-5v2"/>',
  transit: '<rect x="5" y="3" width="14" height="15" rx="4"/><path d="M5 10h14m-11 4h.1m7.9 0h.1M8 18l-2 3m10-3 2 3"/>',
  car: '<path d="m4 11 2-6h12l2 6M3 12l1-1h16l1 1v6H3zm3 6v2m12-2v2m-11-6h1m8 0h1"/>',
  walk: '<circle cx="14" cy="4.5" r="1.8"/><path d="m7 12 3-3 3-1 2 4 4 1m-7-5-2 7-4 6m5-7 4 3 2 4"/>',
  breakfast: '<path d="M4 9h13v5a5 5 0 0 1-5 5H9a5 5 0 0 1-5-5zm13 1h2a2.5 2.5 0 1 1 0 5h-2M3 21h17M7 3v3m4-4v4m4-3v3"/>',
  lunch: '<path d="M3 13h18a9 9 0 0 1-18 0Zm2 7h14M5 10l12-6m-6 6 9-4"/>',
  dinner: '<path d="M5 3v5a3 3 0 1 0 6 0V3M8 3v18m10 0V3c-3 2-4 7-3 10h3"/>',
  nightlife: '<path d="M3 5h18l-9 9-9-9Zm9 9v6m-5 1h10M7 9h10"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  pin: '<path d="M19 10c0 5-7 11-7 11S5 15 5 10a7 7 0 1 1 14 0Z"/><circle cx="12" cy="10" r="2.3"/>',
  external: '<path d="M14 4h6v6m-9 3 9-9M10 5H6a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2v-4"/>',
  money: '<rect x="2" y="5" width="20" height="14" rx="2"/><circle cx="12" cy="12" r="3"/><path d="M5 9h1m12 6h1"/>',
  check: '<path d="m4 12 5 5L20 6"/>',
  chart: '<path d="M3 17v3h18M5 13l5-5 4 3 6-7"/>',
  message: '<path d="M21 12a8 8 0 0 1-8 8H5l-3 2 1-6a8 8 0 1 1 18-4Z"/>',
  image: '<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8" cy="8" r="1.5"/><path d="m4 18 5-5 3 2 4-5 4 6"/>',
  sparkle: '<path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5L12 3Z"/>',
};
export function icon(name) {
  return `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round">${iconPaths[name] ?? iconPaths.pin}</svg>`;
}
export function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, char => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" })[char]);
}
export function safeUrl(value, local = false) {
  if (typeof value !== "string" || !value) return "";
  try {
    const parsed = new URL(value, window.location.origin);
    if (local && value.startsWith("/") && parsed.origin === window.location.origin) return parsed.href;
    return ["http:", "https:"].includes(parsed.protocol) && /^https?:\/\//i.test(value) ? parsed.href : "";
  } catch { return ""; }
}
export function link(url, text, className = "") {
  const href = safeUrl(url);
  return href ? `<a href="${esc(href)}" class="${esc(className)}" target="_blank" rel="noopener noreferrer">${text}</a>` : text;
}
function readable(value) {
  if (value == null) return "";
  if (Array.isArray(value)) return value.map(readable).filter(Boolean).join(" · ");
  if (typeof value === "object") return Object.entries(value).map(([key,v])=>`${prettify(key)}: ${readable(v)}`).join(" · ");
  return String(value);
}
function prettify(text) {
  const spaced = text.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/[_-]/g," ");
  return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}
export function profileView(profile) {
  const rows = Object.entries(profile ?? {}).filter(([,v])=>v !== null && v !== "" && v !== undefined);
  if (!rows.length) return "";
  return `<details class="profile"><summary>Preferences in memory</summary><ul class="detail-list">${rows.map(([key,v])=>`<li><strong>${esc(prettify(key))}</strong> · ${esc(readable(v))}</li>`).join("")}</ul></details>`;
}
function money(value) {
  if (typeof value !== "number") return readable(value);
  return value.toLocaleString("en-US",{style:"currency",currency:"USD",maximumFractionDigits:value % 1 ? 2 : 0});
}
function sources(item) {
  const valid = (item?.sources ?? []).filter(s=>s && safeUrl(s.url));
  if (!valid.length) return "";
  return `<div class="source-links"><span class="sourcelabel">Sources</span>${valid.map(s=>link(s.url, esc(s.label || new URL(s.url).hostname) + icon("external"))).join("")}</div>`;
}
export function credit(value) {
  if (!value) return "";
  if (typeof value === "string") return esc(value);
  return link(value.url, esc(value.label || value.name || "Photo credit"));
}
function photo(item, className = "venue-photo") {
  const src = safeUrl(item.image, true);
  if (!src) return "";
  const alt = esc(item.imageAlt || item.title || item.place || item.name);
  return `<figure class="${className}"><a href="${esc(src)}" target="_blank" rel="noopener" aria-label="Open photograph of ${alt}"><img src="${esc(src)}" alt="${alt}" loading="lazy"></a>${item.imageCredit ? `<figcaption class="photo-credit">${credit(item.imageCredit)}</figcaption>` : ""}</figure>`;
}
function mapAddress(item) {
  if (!item.address) return "";
  const maps = safeUrl(item.mapUrl || item.mapsUrl) || "https://www.google.com/maps/search/?api=1&query=" + encodeURIComponent(item.title + ", " + item.address);
  return link(maps,icon("pin") + esc(item.address),"address") + (safeUrl(item.url) ? " · " + link(item.url,"Directions","address") : "");
}
function time(value) { return value ? `<span class="section-time">${icon("clock")}${esc(value)}</span>` : ""; }
function detailList(item) {
  const keys = {payment:"Payment",diet:"Dietary fit",menu:"Menu",availability:"Availability",wait:"Expected wait",hours:"Hours",rating:"Rating",reservationNote:"Reservations"};
  const entries = Object.entries(keys).filter(([key])=>item[key] != null && item[key] !== "" && typeof item[key] !== "boolean");
  return entries.length ? `<ul class="detail-list">${entries.map(([key,label])=>`<li><strong>${label}</strong> · ${esc(readable(item[key]))}</li>`).join("")}</ul>` : "";
}
function stats(item) {
  const cells = [];
  if (item.price != null) cells.push(`<span>${icon("money")}<strong>${esc(money(item.price))}</strong> est.</span>`);
  if (Number.isFinite(item.minutes)) cells.push(`<span>${icon("clock")}${item.minutes} min</span>`);
  if (Number.isFinite(item.steps)) cells.push(`<span>${icon("walk")}~${item.steps.toLocaleString("en-US")} steps</span>`);
  return cells.length ? `<div class="option-stats">${cells.join("")}</div>` : "";
}
function info(item, withTitle = true) {
  if (!item) return "";
  return `${withTitle ? `<h4 class="venue-title">${esc(item.title)}</h4>` : ""}${mapAddress(item)}${item.notes ? `<p class="option-note">${esc(readable(item.notes))}</p>` : ""}${stats(item)}${detailList(item)}${sources(item)}`;
}
function cardHead(kind, label, right = "") {
  const color = ["event","transit","nightlife"].includes(kind) ? "blue" : kind === "lunch" ? "green" : "";
  return `<div class="card-heading"><div class="head-left"><span class="tile-icon ${color}">${icon(kind)}</span><h3>${esc(label)}</h3></div>${right}</div>`;
}
function eventCard(event) {
  if (!event) return "";
  const image = photo(event);
  const eventTime = event.time || [event.starts,event.ends].filter(Boolean).join(" – ");
  return `<article class="guide-card"><div class="card-inner">${cardHead("event","Your event",time(eventTime))}<div class="${image ? "event-grid" : ""}"><div>${info(event)}</div>${image}</div></div></article>`;
}
function transitIcon(option) {
  const name = (option.title+" "+option.id).toLowerCase();
  return /walk|foot/.test(name) ? "walk" : /car|taxi|uber|lyft|ride|waymo|tesla/.test(name) ? "car" : "transit";
}
function chooseButton(slot, option, label, classes="text-button") {
  return `<button class="${classes}" type="button" data-action="choose" data-slot="${esc(slot)}" data-id="${esc(option.id)}">${esc(label)}</button>`;
}
function transitCard(catalog,state,expanded) {
  const options = catalog.transit;
  if (!options?.length) return "";
  const chosen=options.find(o=>o.id===state.choices?.transit);
  const collapsed=chosen && state.confirmedSlots?.includes("transit") && !expanded;
  const origin = `<p class="origin"><strong>Starting point</strong> · ${esc(catalog.origin)}<br>${link((chosen || options[0]).url,"Map from the public pickup","address")}</p>`;
  const modes = options.map(opt=>`
    <div class="mode-option">
      <button class="mode ${chosen?.id === opt.id ? "selected" : ""}" type="button" aria-pressed="${chosen?.id === opt.id}" data-action="choose" data-slot="transit" data-id="${esc(opt.id)}">
        ${icon(transitIcon(opt))}<span>${esc(opt.title)}</span><small>${esc([money(opt.price),opt.minutes != null ? opt.minutes+" min" : ""].filter(Boolean).join(" · "))}</small>
      </button>
      ${sources({sources:opt.sources?.slice(0,1)})}
    </div>`).join("");
  const compare = `<div class="choice-list" aria-label="Choose transportation">${modes}</div>
    <div class="transit-details">${options.map(opt=>`<details class="compared" ${opt.id === chosen?.id ? "open" : ""}><summary>${esc(opt.title)} details</summary>${info(opt,false)}</details>`).join("")}</div>`;
  const selected = chosen ? `<div class="choice-top"><h4 class="venue-title chosen-title">${icon("check")}${esc(chosen.title)}</h4><button class="text-button" data-toggle-transit type="button">Change mode</button></div>${info(chosen,false)}` : "";
  return `<article class="guide-card" id="transit"><div class="card-inner">
    ${cardHead("transit","Getting there",chosen ? time(chosen.time) : "")}${origin}${collapsed ? selected : compare}
    <div class="commute"><button type="button" class="btn secondary" data-commute>${icon("pin")}Replay commute</button><div id="commute-replay" role="status" aria-live="polite"></div></div>
  </div></article>`;
}
const mealLabels={breakfast:"Breakfast",lunch:"Lunch",dinner:"Dinner",nightlife:"Nightlife"};
function mealCard(slot, options, state) {
  if (!options?.length) return "";
  const current = options.find(o=>o.id === state.choices?.[slot]) || options[0];
  const image = photo(current);
  const selected = state.choices?.[slot] === current.id && state.confirmedSlots?.includes(slot);
  const draft = state.reservation;
  const canReserve=slot === "dinner" && current.reservable === true && selected;
  return `<article class="guide-card" id="slot-${slot}"><div class="card-inner">${cardHead(slot,mealLabels[slot],time(current.time))}
   <div class="select-wrap"><label class="sr-only" for="select-${slot}">Choose ${mealLabels[slot].toLowerCase()}</label><select id="select-${slot}" data-choose-slot="${slot}">${options.map(opt=>`<option value="${esc(opt.id)}" ${opt.id === current.id ? "selected" : ""} ${opt.available===false ? "disabled" : ""}>${esc(opt.title)}${opt.price != null ? " · "+esc(money(opt.price)) : ""}${opt.available===false ? " · unavailable" : ""}</option>`).join("")}</select></div>
   <div class="${image ? "meal-grid" : ""}"><div>${info(current,false)}</div>${image}</div>
   ${!selected ? `<div class="actions">${chooseButton(slot,current,"Confirm "+mealLabels[slot].toLowerCase(),"btn secondary")}</div>` : '<p class="small-state">Confirmed in your plan</p>'}
   ${canReserve ? `<div class="actions"><button class="btn secondary" data-action="reserve" type="button">${icon("calendar")}${draft ? "Review reservation draft" : "Draft a reservation"}</button></div>` : ""}
   ${options.length>1 ? `<details class="compared"><summary>Compare alternatives (${options.length-1})</summary>${options.filter(opt=>opt.id!==current.id).map(opt=>`<div class="alternative">${info(opt)}<div class="actions">${opt.available===false ? "Unavailable" : chooseButton(slot,opt,"Choose "+opt.title)}</div></div>`).join("")}</details>` : ""}
   </div></article>`;
}
function contactIsInvited(state,id) {
  return (state.invitations ?? []).some(value=>value===id || value.id===id || value.contactId===id);
}
function socialPost(contact, state) {
  const name = esc(contact.name);
  const initials = esc(contact.name.split(" ").map(word => word[0]).slice(0, 2).join(""));
  const isStory = /instagram/i.test(contact.platform);
  const actions = `<div class="actions">
    <button class="btn secondary" type="button" data-action="invite" data-id="${esc(contact.id)}">
      ${icon("message")}${contactIsInvited(state,contact.id) ? "Review invite draft" : "Draft an invite"}
    </button>
  </div>`;
  const byline = `<div class="post-byline">
    <span class="post-avatar" aria-hidden="true">${initials}</span>
    <div><h3>${name}</h3><span class="post-platform">${esc(contact.platform)} · fictional</span></div>
  </div>`;
  const place = contact.place
    ? `<span class="post-place">${icon("pin")}${esc(contact.place)}</span>`
    : "";
  if (isStory) {
    return `<article class="social story-post">
      <div class="story-picture">
        ${photo(contact,"social-media")}
        <div class="story-byline">${byline}</div>
        ${place}
      </div>
      <div class="card-inner"><p class="option-note">${esc(contact.caption)}</p>${actions}</div>
    </article>`;
  }
  return `<article class="social x-post">
    <div class="card-inner">
      <div class="post-heading">${byline}<span class="platform-symbol" aria-hidden="true">𝕏</span></div>
      <p class="option-note">${esc(contact.caption)}</p>
      ${place}${photo(contact,"social-media")}${actions}
    </div>
  </article>`;
}
function people(catalog,state) {
  const interruptionStatus = {
    rerouted: "The alternative route is in your plan.",
    dismissed: "You kept your original route."
  }[state.alert] || "See how a new post can change the evening.";
  return `<section class="group" id="people" aria-labelledby="people-heading">
    <h2 class="group-title" id="people-heading">People nearby</h2>
    <div class="social-grid">${(catalog.contacts || []).map(c => socialPost(c,state)).join("")}</div>
    ${catalog.alert ? `<div class="interrupt">
      <div><strong>Social interruption</strong><p>${interruptionStatus}</p></div>
      <button data-action="alert" type="button" class="btn secondary">
        ${state.alert==="idle" ? "Show interruption" : "Review interruption"}
      </button>
    </div>` : ""}
  </section>`;
}
function prettyDate(value,compact=false) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return value;
  return new Intl.DateTimeFormat("en-US",{weekday:compact ? "short" : "long",month:"short",day:"numeric",timeZone:"UTC"}).format(new Date(value+"T12:00:00Z"));
}
function weekend(items) {
  return `<section class="group" id="weekend" aria-labelledby="weekend-heading"><h2 class="group-title" id="weekend-heading">This weekend</h2><div class="weekend-grid">${(items || []).map(item=>`<article class="weekend"><div class="card-inner">${time([prettyDate(item.date,true),item.time].filter(Boolean).join(" · "))}<h3>${esc(item.title)}</h3>${info(item,false)}</div></article>`).join("")}</div></section>`;
}
const checkDateFormat = new Intl.DateTimeFormat("en-US", {
  month:"short", day:"numeric", year:"numeric", hour:"numeric", minute:"2-digit",
  timeZoneName:"short", timeZone:"America/Los_Angeles"
});
const replayDateFormat = new Intl.DateTimeFormat("en-CA", {
  year:"numeric", month:"2-digit", day:"2-digit", hour:"2-digit", minute:"2-digit",
  hourCycle:"h23", timeZone:"America/Los_Angeles"
});
function checkDate(value) {
  const date = new Date(value);
  return value && Number.isFinite(date.getTime()) ? checkDateFormat.format(date) : "";
}
function replayStamp(instant) {
  if (!checkDate(instant)) return "";
  const parts = Object.fromEntries(replayDateFormat.formatToParts(new Date(instant)).map(p => [p.type,p.value]));
  return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}`;
}
function organizerFacts(facts,event) {
  if (!facts?.start || !event) return "";
  const changed = replayStamp(facts.start) !== event.date+" "+event.starts
    || (facts.end && replayStamp(facts.end) !== event.date+" "+event.ends)
    || (facts.eventStatus && facts.eventStatus !== "Scheduled");
  return `<p>Organizer start · ${esc(checkDate(facts.start))}</p>
    ${facts.end ? `<p>Organizer end · ${esc(checkDate(facts.end))}</p>` : ""}
    ${facts.eventStatus ? `<p>Organizer status · ${esc(facts.eventStatus)}</p>` : ""}
    ${changed ? `<p class="changed-facts"><strong>Different from the replay</strong><br>
      Replay schedule · ${esc(event.date)} · ${esc(event.time)}</p>` : ""}`;
}
function evidencePanel(evidence,catalog) {
  if (!evidence) return "";
  const rows = (evidence.sources || []).map(source => {
    const checkedAt = checkDate(source.checkedAt);
    const lastGood = checkDate(source.lastGoodAt);
    return `<li>
      <strong>${link(source.url,esc(source.label)+icon("external"))}</strong>
      <p>${esc(source.status)}</p>
      ${checkedAt ? `<p>Checked · ${esc(checkedAt)}</p>` : ""}
      ${lastGood && source.lastGoodAt !== source.checkedAt ? `<p>Last verified · ${esc(lastGood)}</p>` : ""}
      ${organizerFacts(source.facts,catalog.event)}
      ${source.id === "weather" && evidence.weather ? `<p>${esc(evidence.weather)}</p>` : ""}
      ${source.facts?.sha256 && source.changedAt ? `<p>Menu file version first seen · ${esc(checkDate(source.changedAt))}</p>` : ""}
    </li>`;
  }).join("");
  return `<details class="tips source-checks">
    <summary>Source checks</summary><p>${esc(evidence.status)}</p>
    <ul>${rows}</ul>
  </details>`;
}
function trackerView(catalog,state,tracker,memoryStatus,evidence) {
  const lines = tracker.lines ?? [];
  const metrics = [
    [money(tracker.cost ?? 0), "Est. spend", "of "+money(state.profile.budget)+" budget"],
    [Number(tracker.steps ?? 0).toLocaleString("en-US"), "Steps", Number(state.profile.walkingGoal).toLocaleString("en-US")+" goal"],
    [Number(tracker.calories ?? 0).toLocaleString("en-US"), "kcal", "estimated"]
  ];
  const timeline = lines.map(line => `<li><div class="timeline-line">
    <time>${esc(line.time)}</time>${link(line.url,esc(line.title))}
  </div></li>`).join("");
  return `<aside class="sidebar" id="tracker" aria-label="Trip estimates">
   <section class="tracker">
     <div class="tracker-head">
       <div class="title-with-icon">${icon("chart")}<h2>Trip tracker</h2></div>
       <span class="tracker-state">${state.started ? "Planned" : "Preview"}</span>
     </div>
     <div class="metrics">${metrics.map(([value,label,goal])=>`<div class="metric">
       <strong class="metric-value">${esc(value)}</strong><span class="metric-label">${label}</span>
       <span class="metric-goal">${esc(goal)}</span>
     </div>`).join("")}</div>
     <div class="timeline-wrap">
       <h3>Your schedule</h3>
       ${lines.length ? `<ol class="timeline">${timeline}</ol>` : '<p class="subtle">Start your briefing to build your schedule.</p>'}
     </div>
     <p class="tracker-foot">Projected from your itinerary. Route and activity estimates change with your choices.</p>
   </section>
   <details class="tips expenses"><summary>Spending log · ${esc(money(tracker.spent ?? 0))}</summary><p>Daily budget · ${esc(money(state.profile.budget))}</p>
   ${(state.expenses || []).length ? `<ul class="expense-list">${state.expenses.map(entry=>`<li><span>${esc(entry.label)}</span><strong>${esc(money(entry.amount))}</strong></li>`).join("")}</ul>` : ""}
   <form id="expense-form"><label>Expense<input name="label" maxlength="80" placeholder="e.g. Clipper fare" required></label><label>Amount (USD)<input name="amount" type="number" min="0.01" max="10000" step="0.01" placeholder="0.00" required></label><button class="btn secondary" type="submit">Log expense</button></form></details>
   <details class="tips"><summary>Weather & visitor tips</summary>${catalog.weather ? `<p>${esc(readable(catalog.weather))}</p>` : ""}<ul>${(catalog.visitorTips ?? []).map(tip=>`<li>${esc(readable(tip))}</li>`).join("")}</ul>${sources({sources:[...(catalog.weatherSources || []),...(catalog.visitorSources || catalog.tipSources || [])]})}</details>
   <div class="trip-memory">${profileView(state.profile)}</div>
   ${evidencePanel(evidence,catalog)}
   <details class="tips recall"><summary>Recall a memory</summary>
     <form id="recall-form"><label>Search in<select name="scope"><option value="private">My trip</option><option value="shared">City guide</option></select></label>
       <label>Search memory<input name="query" type="search" placeholder="e.g. breakfast" maxlength="250" required></label>
       <button class="btn secondary" type="submit">Search</button>
     </form><p id="recall-status" role="status">${esc(memoryStatus)}</p><ul id="recall-results"></ul>
   </details>
   ${state.started ? `<button type="button" class="text-button reset-button" data-reset>Reset demo</button>` : ""}</aside>`;
}
function guideBriefing(paragraphs) {
  const [intro,...rest] = (paragraphs ?? []).filter(text => typeof text === "string" && text.trim());
  if (!intro) return "";
  const supportsSpeech = "speechSynthesis" in window && typeof window.SpeechSynthesisUtterance === "function";
  return `<section class="guide-response" aria-labelledby="guide-response-heading">
    <div class="card-heading">
      <h3 id="guide-response-heading">Atmos’ briefing</h3>
      ${supportsSpeech ? '<button class="btn secondary" type="button" id="read-guide" aria-pressed="false">Read aloud</button>' : ""}
    </div>
    <p class="guide-intro">${esc(intro)}</p>
    ${rest.length ? `<details class="guide-detail"><summary>Full briefing</summary>
      ${rest.map(text => `<p>${esc(text)}</p>`).join("")}
    </details>` : ""}
    <span id="reading-status" role="status" class="sr-only"></span>
  </section>`;
}
export function dashboard(data,expanded) {
  const {catalog,state,tracker}=data;
  return `<div class="workspace"><div class="plan-column"><section id="day-plan" aria-labelledby="plan-heading"><div class="heading-row"><h2 id="plan-heading">Your itinerary</h2>${catalog.date ? `<span class="context-date">${icon("calendar")}${esc(prettyDate(catalog.date))}</span>` : ""}<a class="text-button tracker-link" href="#tracker">Trip tracker</a></div>
  ${state.started ? guideBriefing(data.briefing) : ""}
  ${eventCard(catalog.event)}${transitCard(catalog,state,expanded)}
  ${["breakfast","lunch","dinner"].map(slot=>mealCard(slot,catalog[slot],state)).join("")}
  </section>${people(catalog,state)}
  <section class="group" aria-label="Nightlife options">${mealCard("nightlife",catalog.nightlife,state)}</section>
  ${weekend(catalog.weekend)}</div>
  ${trackerView(catalog,state,tracker,data.memoryStatus,data.evidence)}</div>`;
}
export function alertView(alert) {
  return `<div class="dialog-heading"><span class="eyebrow">Fictional social update</span><button type="button" class="icon-button" data-close="alert-dialog" aria-label="Close interruption">×</button></div><h2 id="alert-title">${esc(alert.title || "A change of plans")}</h2>${photo(alert,"alert-photo")}${alert.place ? `<p class="address">${icon("pin")}${esc(alert.place)}</p>` : ""}<p class="option-note">${esc(alert.caption)}</p><p class="subtle">${esc(readable(alert.notes))}</p>${alert.alternative ? `<p class="option-note">Alternative · ${esc(readable(alert.alternative))}</p>` : ""}<div class="dialog-actions"><button type="button" class="btn secondary" data-action="dismiss">Keep my plan</button><button type="button" class="btn primary" data-action="reroute">Reroute my evening</button></div>`;
}
